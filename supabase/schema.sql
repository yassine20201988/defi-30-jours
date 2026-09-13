-- =====================================================================
--  Défi 30 jours — schéma complet
--  Supabase SQL Editor → coller en une fois. Idempotent, ré-exécutable.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Nettoyage idempotent
--    NB : "drop trigger if exists ... on T" exige que T existe deja.
--    On teste donc la presence de la table avant, sinon la 1re execution
--    sur une base vierge echoue en 42P01.
-- ---------------------------------------------------------------------
drop trigger if exists on_auth_user_created on auth.users;

do $do$
begin
  if to_regclass('public.profiles') is not null then
    execute 'drop trigger if exists profiles_validate_biu on public.profiles';
    execute 'drop trigger if exists profiles_touch_bu     on public.profiles';
  end if;
  if to_regclass('public.day_entries') is not null then
    execute 'drop trigger if exists day_entries_touch_bu on public.day_entries';
  end if;
end
$do$;

-- ---------------------------------------------------------------------
-- 1. Table profils : 1 ligne par compte auth
--    display_name  = SEULE donnée jamais partagée (via leaderboard())
--    start_date / weight_target / timezone = privés, jamais renvoyés
--    à un autre utilisateur par aucun chemin.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id                   uuid primary key
                         references auth.users (id) on delete cascade,
  display_name         text        not null,
  start_date           date        not null default current_date,
  weight_target        numeric(5,2),
  timezone             text        not null default 'Europe/Paris',
  share_on_leaderboard boolean     not null default true,
  legacy_migrated_at   timestamptz,   -- migration one-shot des donnees pre-comptes
  group_code           text,          -- cercle d'amis ; auto-genere = solo par defaut
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint profiles_display_name_len
    check (char_length(display_name) between 1 and 24),
  constraint profiles_weight_target_range
    check (weight_target is null or weight_target between 20 and 300),
  constraint profiles_group_code_fmt
    check (group_code is null or group_code ~ '^[a-z0-9]{4,16}$'),
  constraint profiles_start_date_sane
    check (start_date between date '2020-01-01' and date '2100-01-01')
);

comment on column public.profiles.weight_target is
  'PRIVÉ — ne doit apparaître dans aucune fonction/vue lisible par un tiers.';
comment on column public.profiles.display_name is
  'PUBLIC entre participants — exposé uniquement par public.leaderboard().';

-- ---------------------------------------------------------------------
-- 2. Table journées : 1 ligne par (utilisateur, date civile)
--    score = colonne générée -> le classement n'a rien à recalculer
--    et le client ne peut pas l'envoyer (Postgres refuse l'écriture).
-- ---------------------------------------------------------------------
create table if not exists public.day_entries (
  user_id     uuid        not null
                references public.profiles (id) on delete cascade,
  entry_date  date        not null,

  weight      numeric(5,2),          -- PRIVÉ
  sleep       numeric(3,1),          -- PRIVÉ
  sport       boolean     not null default false,
  english     boolean     not null default false,
  no_white    boolean     not null default false,
  no_slow     boolean     not null default false,
  run_km      numeric(5,2),          -- PRIVÉ
  run_min     integer,               -- PRIVÉ
  run_fc      smallint,              -- PRIVÉ
  run_place   text,                  -- PRIVÉ

  score smallint generated always as (
      (case when weight is not null then 1 else 0 end)
    + (case when sport    then 1 else 0 end)
    + (case when english  then 1 else 0 end)
    + (case when no_white then 1 else 0 end)
    + (case when no_slow  then 1 else 0 end)
  ) stored,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  primary key (user_id, entry_date),

  constraint day_entries_date_sane   check (entry_date between date '2020-01-01' and date '2100-01-01'),
  constraint day_entries_weight_rng  check (weight  is null or weight  between 20 and 300),
  constraint day_entries_sleep_rng   check (sleep   is null or sleep   between 0  and 24),
  constraint day_entries_km_rng      check (run_km  is null or run_km  between 0  and 300),
  constraint day_entries_min_rng     check (run_min is null or run_min between 0  and 1440),
  constraint day_entries_fc_rng      check (run_fc  is null or run_fc  between 30 and 250),
  constraint day_entries_place_enum  check (run_place is null or run_place in ('tapis','outdoor'))
);

-- ---------------------------------------------------------------------
-- 3. Index
--    La PK (user_id, entry_date) sert : le chargement complet d'un user,
--    l'upsert par jour, et la jointure du classement. Rien d'autre
--    n'est justifié à cette échelle (quelques dizaines de comptes).
-- ---------------------------------------------------------------------
-- Utile seulement si le groupe dépasse ~1000 comptes :
-- create index if not exists day_entries_perfect_idx
--   on public.day_entries (user_id) where score = 5;

-- ---------------------------------------------------------------------
-- 4. Triggers utilitaires : updated_at + normalisation profil
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch_bu
  before update on public.profiles
  for each row execute function public.touch_updated_at();

create trigger day_entries_touch_bu
  before update on public.day_entries
  for each row execute function public.touch_updated_at();

-- Normalise au lieu de rejeter : ce trigger tourne aussi pendant
-- l'inscription, il ne doit JAMAIS faire échouer un signup.
create or replace function public.profiles_normalize()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.display_name := left(btrim(coalesce(new.display_name, '')), 24);
  if new.display_name = '' then
    new.display_name := 'Participant';
  end if;
  -- Cercle : chacun est seul par defaut, il faut le code d'un ami pour le rejoindre.
  new.group_code := lower(btrim(coalesce(new.group_code, '')));
  if new.group_code = '' then
    new.group_code := left(replace(new.id::text, '-', ''), 8);
  end if;
  if not exists (
    select 1 from pg_catalog.pg_timezone_names z where z.name = new.timezone
  ) then
    new.timezone := 'Europe/Paris';
  end if;
  return new;
end;
$$;

create trigger profiles_validate_biu
  before insert or update on public.profiles
  for each row execute function public.profiles_normalize();

-- ---------------------------------------------------------------------
-- 5. Création automatique du profil à l'inscription
--    SECURITY DEFINER + search_path figé. Aucune création côté client,
--    donc aucune course possible entre signup et première écriture.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, start_date, timezone)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      split_part(coalesce(new.email, 'participant@x'), '@', 1)
    ),
    coalesce(
      (new.raw_user_meta_data ->> 'start_date')::date,
      (now() at time zone
        coalesce(nullif(new.raw_user_meta_data ->> 'timezone',''), 'Europe/Paris')
      )::date
    ),
    coalesce(nullif(new.raw_user_meta_data ->> 'timezone', ''), 'Europe/Paris')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Rattrapage des comptes créés avant ce script :
insert into public.profiles (id, display_name)
select u.id, split_part(coalesce(u.email,'participant@x'), '@', 1)
from auth.users u
on conflict (id) do nothing;

-- Backfill du cercle pour les profils anterieurs a cette colonne :
update public.profiles p
   set group_code = left(replace(p.id::text, '-', ''), 8)
 where p.group_code is null;

-- ---------------------------------------------------------------------
-- 6. RLS — activée sur les deux tables, aucune ligne visible par défaut
-- ---------------------------------------------------------------------
alter table public.profiles    enable row level security;
alter table public.day_entries enable row level security;

-- PROFILES ------------------------------------------------------------
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
  on public.profiles for select to authenticated
  using ( (select auth.uid()) = id );

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own
  on public.profiles for insert to authenticated
  with check ( (select auth.uid()) = id );

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
  on public.profiles for update to authenticated
  using      ( (select auth.uid()) = id )   -- quelles lignes je peux viser
  with check ( (select auth.uid()) = id );  -- à quoi la ligne a le droit de ressembler après

-- pas de policy DELETE : la suppression passe par la suppression du compte
-- auth.users (cascade FK, exécutée hors RLS par le service auth).

-- DAY_ENTRIES ---------------------------------------------------------
drop policy if exists day_entries_select_own on public.day_entries;
create policy day_entries_select_own
  on public.day_entries for select to authenticated
  using ( (select auth.uid()) = user_id );

drop policy if exists day_entries_insert_own on public.day_entries;
create policy day_entries_insert_own
  on public.day_entries for insert to authenticated
  with check ( (select auth.uid()) = user_id );

drop policy if exists day_entries_update_own on public.day_entries;
create policy day_entries_update_own
  on public.day_entries for update to authenticated
  using      ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

drop policy if exists day_entries_delete_own on public.day_entries;
create policy day_entries_delete_own
  on public.day_entries for delete to authenticated
  using ( (select auth.uid()) = user_id );

-- ---------------------------------------------------------------------
-- 7. Privilèges SQL (2e barrière, indépendante de RLS)
--    Supabase accorde par défaut les nouvelles tables à anon : on retire.
-- ---------------------------------------------------------------------
revoke all on public.profiles    from anon;
revoke all on public.day_entries from anon;

grant select, insert, update                 on public.profiles    to authenticated;
grant select, insert, update, delete         on public.day_entries to authenticated;

-- ---------------------------------------------------------------------
-- 8. CLASSEMENT — unique fenêtre vers les données d'autrui.
--    SECURITY DEFINER : contourne volontairement la RLS, mais le type de
--    retour ne contient QUE 7 colonnes agrégées. Le poids ne peut pas
--    sortir : il n'existe aucune colonne pour le transporter.
-- ---------------------------------------------------------------------
create or replace function public.leaderboard()
returns table (
  participant_id uuid,
  display_name   text,
  perfect_days   integer,
  current_streak integer,
  completion_pct integer,
  elapsed_days   integer,
  perfect_rate   integer,   -- CLE DE TRI : jours parfaits / SES propres jours ecoules
  reg_index      integer,   -- variante amortie (perfect / (elapsed+3)), non triante
  is_me          boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_group text;
begin
  if v_uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;

  -- Le cercle de l'appelant. On ne voit QUE les gens qui partagent ce code.
  select p.group_code into v_group from public.profiles p where p.id = v_uid;
  if v_group is null then
    return;                       -- profil pas encore cree : classement vide
  end if;

  return query
  with participant as (
    select
      p.id                                          as pid,
      p.display_name                                as pname,
      p.start_date                                  as pstart,
      (now() at time zone p.timezone)::date         as ptoday,
      least(30, greatest(0,
        ((now() at time zone p.timezone)::date - p.start_date) + 1
      ))::int                                       as pelapsed
    from public.profiles p
    where p.share_on_leaderboard
      and p.group_code = v_group
  ),
  grid as (
    select pa.pid, pa.ptoday, (pa.pstart + g.n)::date as day
    from participant pa
    cross join lateral generate_series(0, pa.pelapsed - 1) as g(n)
  ),
  scored as (
    select gr.pid, gr.day, gr.ptoday, coalesce(de.score, 0)::int as day_score
    from grid gr
    left join public.day_entries de
      on de.user_id = gr.pid and de.entry_date = gr.day
  ),
  totals as (
    select s.pid,
           count(*) filter (where s.day_score = 5)::int as perfect,
           coalesce(sum(s.day_score), 0)::int           as points
    from scored s group by s.pid
  ),
  eligible as (
    select s.* from scored s
    where not (s.day = s.ptoday and s.day_score < 5)
  ),
  streak_scan as (
    select e.pid,
           bool_and(e.day_score = 5) over (
             partition by e.pid order by e.day desc
             rows between unbounded preceding and current row
           ) as in_streak
    from eligible e
  ),
  streaks as (
    select t.pid, count(*) filter (where t.in_streak)::int as streak
    from streak_scan t group by t.pid
  ),
  final as (
    select
      pa.pid, pa.pname, pa.pstart, pa.pelapsed,
      coalesce(tt.perfect, 0)                                as perfect,
      coalesce(st.streak, 0)                                 as streak,
      case when pa.pelapsed = 0 then 0
           else round((100.0 * coalesce(tt.points, 0)) / (5 * pa.pelapsed))::int
      end                                                    as completion,
      case when pa.pelapsed = 0 then 0
           else round((100.0 * coalesce(tt.perfect, 0)) / pa.pelapsed)::int
      end                                                    as prate,
      round((100.0 * coalesce(tt.perfect, 0)) / (pa.pelapsed + 3))::int as rindex
    from participant pa
    left join totals  tt on tt.pid = pa.pid
    left join streaks st on st.pid = pa.pid
  )
  select f.pid, f.pname, f.perfect, f.streak, f.completion,
         f.pelapsed, f.prate, f.rindex, (f.pid = v_uid)
  from final f
  -- Equite d'abord (taux, invariant a la date de depart), volume ensuite.
  -- Departage TOTAL : sans lui la liste se reordonne visiblement a chaque fetch.
  order by f.prate desc, f.perfect desc, f.streak desc, f.completion desc,
           f.pstart asc, lower(f.pname) asc, f.pid asc;
end;
$$;

revoke all     on function public.leaderboard() from public, anon;
grant  execute on function public.leaderboard() to authenticated;

-- ---------------------------------------------------------------------
-- 9. Filet de sécurité : profil manquant (compte créé hors trigger,
--    OAuth ajouté plus tard, etc.). Idempotent, clé = auth.uid().
-- ---------------------------------------------------------------------
create or replace function public.ensure_profile(p_display_name text default null)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_row public.profiles;
begin
  if v_uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;

  insert into public.profiles (id, display_name)
  values (
    v_uid,
    coalesce(
      nullif(btrim(p_display_name), ''),
      split_part(
        coalesce((select u.email from auth.users u where u.id = v_uid), 'participant@x'),
        '@', 1)
    )
  )
  on conflict (id) do nothing;

  select p.* into v_row from public.profiles p where p.id = v_uid;
  return v_row;
end;
$$;

revoke all     on function public.ensure_profile(text) from public, anon;
grant  execute on function public.ensure_profile(text) to authenticated;

-- ---------------------------------------------------------------------
-- 10. Changement de date de début — deux sémantiques explicites.
--     SECURITY INVOKER : la RLS s'applique, la fonction ne peut toucher
--     que les lignes de l'appelant, même en cas de bug.
-- ---------------------------------------------------------------------
create or replace function public.set_start_date(
  p_new_start     date,
  p_shift_entries boolean default false
)
returns public.profiles
language plpgsql
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_old   date;
  v_delta integer;
  v_row   public.profiles;
begin
  if v_uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;

  select p.start_date into v_old from public.profiles p where p.id = v_uid;
  if v_old is null then
    raise exception 'Profil introuvable' using errcode = 'P0002';
  end if;

  v_delta := p_new_start - v_old;

  if p_shift_entries and v_delta <> 0 then
    -- décalage sans collision de PK : sortie complète puis réinsertion
    create temporary table if not exists _shift (like public.day_entries)
      on commit drop;
    delete from pg_temp._shift;

    insert into pg_temp._shift
      select * from public.day_entries d where d.user_id = v_uid;

    delete from public.day_entries d where d.user_id = v_uid;

    insert into public.day_entries
      (user_id, entry_date, weight, sleep, sport, english, no_white, no_slow,
       run_km, run_min, run_fc, run_place)
    select m.user_id, m.entry_date + v_delta, m.weight, m.sleep, m.sport,
           m.english, m.no_white, m.no_slow, m.run_km, m.run_min, m.run_fc, m.run_place
    from pg_temp._shift m;
  end if;

  update public.profiles p set start_date = p_new_start where p.id = v_uid;

  select p.* into v_row from public.profiles p where p.id = v_uid;
  return v_row;
end;
$$;

revoke all     on function public.set_start_date(date, boolean) from public, anon;
grant  execute on function public.set_start_date(date, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 11. (OPTIONNEL) Inscription sur invitation seulement.
--     À décommenter le jour où des inconnus s'inscrivent.
-- ---------------------------------------------------------------------
-- create table if not exists public.invited_emails (
--   email text primary key,
--   added_at timestamptz not null default now()
-- );
-- alter table public.invited_emails enable row level security;  -- 0 policy = invisible aux clients
-- revoke all on public.invited_emails from anon, authenticated;
--
-- create or replace function public.enforce_invite()
-- returns trigger language plpgsql security definer set search_path = '' as $$
-- begin
--   if not exists (select 1 from public.invited_emails i
--                  where lower(i.email) = lower(new.email)) then
--     raise exception 'Inscription sur invitation uniquement';
--   end if;
--   return new;
-- end; $$;
-- create trigger enforce_invite_bi before insert on auth.users
--   for each row execute function public.enforce_invite();

-- ---------------------------------------------------------------------
-- 12. Smoke tests (à exécuter connecté depuis l'app, pas dans l'éditeur SQL
--     qui tourne en postgres et contourne la RLS) :
--   select * from public.leaderboard();
--   select count(*) from public.day_entries;   -- doit = mes lignes seulement
-- ---------------------------------------------------------------------
