# CollabTask Database (Supabase/PostgreSQL)

This folder manages the PostgreSQL schema for CollabTask, designed to be compatible with Supabase. It includes:
- Core entities: users (dev-only), organizations, memberships, projects, tasks
- Collaboration: comments, attachments, task activity
- Billing: org subscriptions and invoices (Stripe)
- Integrations: GitHub, OpenAI, inbound webhooks
- Secure Row-Level Security (RLS) policies based on organization membership

## Quick start

1) Ensure a PostgreSQL instance is running. A simple local startup helper is provided:
   ./startup.sh

2) Configure environment variables. Copy .env.example to .env and adjust:
   POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD

3) Apply migrations:
   ./migrate.sh

Migrations are applied in lexicographic order from the schema/ directory:
- 001_init.sql: core tables
- 002_rls.sql: RLS helpers and core policies
- 003_comments_billing_integrations.sql: comments, attachments, task activity, billing, integrations

## Row-Level Security (RLS)

RLS is enabled on all user data tables. Access is granted to rows belonging to organizations the current user is a member of. The current user is resolved via:
- JWT claim app.user_id or sub (Supabase default), or
- Session GUC app.user_id for local development (set using: SELECT set_config('app.user_id','<uuid>', false);).

In Supabase production, JWT claims will be present and no manual GUC is needed.

## Scripts

- startup.sh: Starts local PostgreSQL and ensures a user/database exist, writes db_visualizer/postgres.env and db_connection.txt
- migrate.sh: Loads env, validates connectivity, applies schema/*.sql
- backup_db.sh / restore_db.sh: Portable backup/restore helpers
- db_visualizer/: Minimal DB viewer for local inspection

## Notes

- The table public.auth_users exists for local/dev only; in Supabase production, use auth.users from the auth schema instead. The RLS functions and policies assume the user's UUID is available in the JWT claims.
- Adjust policies or claim extraction in public.get_current_user_id() if your auth setup differs.
