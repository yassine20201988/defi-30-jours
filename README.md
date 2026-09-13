# Défi 30 jours

Suivi de défi personnel sur 30 jours — pesée, sommeil, course et 4 habitudes
quotidiennes, avec classement partagé entre amis.

**En ligne :** https://yassine20201988.github.io/defi-30-jours/

## Architecture

Une seule page statique (`index.html`, sans build) servie par GitHub Pages,
adossée à Supabase pour les comptes, la synchronisation et le classement.

- **Hors ligne d'abord** : `localStorage` répond immédiatement, une file
  d'attente pousse les écritures dès que le réseau revient.
- **Confidentialité structurelle** : poids, objectif, sommeil et détail des
  courses ne quittent jamais le compte. Le classement passe par une fonction
  `SECURITY DEFINER` dont le type de retour ne contient aucune colonne capable
  de les transporter.
- **Cercles** : chaque compte reçoit un code ; on ne voit que les participants
  qui partagent le même code.

## Base de données

Le schéma complet (tables, RLS, triggers, fonction de classement) est dans
[`supabase/schema.sql`](supabase/schema.sql). Il est idempotent : le coller
dans le SQL Editor de Supabase suffit, et il peut être rejoué sans risque.

## Développement local

```
node serve.js     # http://localhost:4173
```
