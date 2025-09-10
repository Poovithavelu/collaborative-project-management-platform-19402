# CollabTask Database (Supabase/PostgreSQL)

This folder contains the database schema and operational scripts for CollabTask. It targets a PostgreSQL instance compatible with Supabase (RLS policies, JWT claim helpers, etc.). This guide is for new contributors and ops to set up, run, migrate, and integrate the database.

Sections:
- 1) Environment and .env setup
- 2) Starting local PostgreSQL (startup.sh)
- 3) Running migrations (migrate.sh) and expected files
- 4) Schema summary (all created tables and domain objects)
- 5) Troubleshooting migrations and ordering
- 6) Integration notes for the backend API

--------------------------------------------------------------------------------

1) Environment and .env setup

The scripts and migrations expect standard PostgreSQL env variables:

Required variables:
- POSTGRES_HOST: Hostname (default used by scripts: localhost)
- POSTGRES_PORT: Port for Postgres (example in scripts: 5000)
- POSTGRES_DB: Database name (example in scripts: myapp)
- POSTGRES_USER: App user (example in scripts: appuser)
- POSTGRES_PASSWORD: Password for the app user

Optional variables:
- POSTGRES_URL: Full connection URL, e.g. postgresql://localhost:5000/myapp
  (Used by db_visualizer; migrate.sh builds its own flags from individual vars.)

Set them in one of the following:
- database_supabase/.env (preferred)
- database_supabase/postgres.env (alternative)
- database_supabase/db_visualizer/postgres.env (auto-created by startup.sh; usable as a source file)
- Current shell environment (exported before running scripts)

Example .env (create at collaborative-project-management-platform-19402/database_supabase/.env):
POSTGRES_HOST=localhost
POSTGRES_PORT=5000
POSTGRES_DB=myapp
POSTGRES_USER=appuser
POSTGRES_PASSWORD=dbuser123

Note:
- Do not commit real secrets. This repository may include example values for convenience; in real environments, use secure secret management.
- The startup.sh script will generate db_visualizer/postgres.env and db_connection.txt for convenience when starting a local Postgres daemon.

--------------------------------------------------------------------------------

2) Starting local PostgreSQL (startup.sh)

Script: startup.sh
Purpose: Initialize (if needed) and start a local PostgreSQL instance on the configured port, create the app database and user, and ensure proper permissions.

What it does:
- Detects installed PostgreSQL binaries (/usr/lib/postgresql/<version>/bin)
- Skips if Postgres is already running on the configured port
- Initializes data dir if not present
- Starts Postgres in the background on the specified port
- Creates DB and user if they don’t exist
- Grants permissions on public schema
- Writes convenience files:
  - db_connection.txt: psql connection command
  - db_visualizer/postgres.env: exported env vars for db viewer and scripts

Usage:
1) cd collaborative-project-management-platform-19402/database_supabase
2) Ensure you have PostgreSQL installed (client + server)
3) Run: ./startup.sh
4) Verify readiness: The script prints connection info and a psql command.

Connecting:
- Use the printed command or:
  psql -h localhost -U appuser -d myapp -p 5000
- Or copy from db_connection.txt (created by the script).

Note:
- startup.sh is tuned for a standard Linux environment path layout. If your OS differs, you may need to adjust PG_BIN paths or run a PostgreSQL service separately and just ensure the .env variables point to it.

--------------------------------------------------------------------------------

3) Running migrations (migrate.sh) and expected files

Script: migrate.sh
Purpose: Apply all SQL migration files from schema/ in lexicographical order to the configured database.

Where migrations live:
- collaborative-project-management-platform-19402/database_supabase/schema/
- Files are numbered to enforce order: 001_init.sql, 002_rls.sql, 003_domain.sql, 004_domain_rls.sql

What migrate.sh does:
- Loads env from:
  - ./.env if present
  - ./postgres.env if present
  - ./db_visualizer/postgres.env if present
  - Otherwise relies on current environment
- Validates required variables:
  POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_HOST, POSTGRES_PORT
- Verifies connectivity using psql
- Applies all *.sql files in schema/ in sorted order, stopping on first error

Usage:
1) cd collaborative-project-management-platform-19402/database_supabase
2) Ensure env variables are set (see section 1). If you ran ./startup.sh, you can:
   source db_visualizer/postgres.env
3) Run:
   ./migrate.sh
4) Expect to see “All migrations applied successfully.” if everything succeeded.

Expected files in schema/:
- 001_init.sql:
  - Core tables: auth_users (dev-only), organizations, memberships, projects, tasks
  - Triggers for updated_at tracking
  - Extensions: pgcrypto
- 002_rls.sql:
  - RLS enablement and policies for core tables
  - Helper function get_current_user_id() to extract JWT/GUC user id
- 003_domain.sql:
  - Domain tables: comments, attachments, project_github_repos, subscriptions, integrations, ai_sessions, audit_logs
  - Audit trigger function audit_log_row_change() and indices
  - tasks_reorder_bulk() utility function + composite type task_order_patch
- 004_domain_rls.sql:
  - RLS policies for domain tables added in 003_domain.sql
  - Explicit SELECT/INSERT/UPDATE/DELETE policies per table

--------------------------------------------------------------------------------

4) Schema summary (tables and domain objects)

Core (001_init.sql):
- public.auth_users (dev-only)
  - id, email, hashed_password, name, avatar_url, created_at, updated_at
  - updated_at trigger
  - Unique: email
- public.organizations
  - id, name, owner_id, created_at, updated_at
  - FK: owner_id -> auth_users.id
  - updated_at trigger
- public.memberships
  - id, org_id, user_id, role (‘owner’, ‘admin’, ‘member’), created_at, updated_at
  - FK: org_id -> organizations.id (cascade), user_id -> auth_users.id (cascade)
  - Unique: (org_id, user_id)
  - updated_at trigger
- public.projects
  - id, org_id, name, description, status (‘active’, ‘archived’), created_by, created_at, updated_at
  - FK: org_id -> organizations.id (cascade), created_by -> auth_users.id (set null)
  - updated_at trigger
- public.tasks
  - id, project_id, title, description, status, priority, assignee_id, due_date, order_index, created_at, updated_at
  - FK: project_id -> projects.id (cascade), assignee_id -> auth_users.id (set null)
  - Indices for common queries
  - updated_at trigger

Core RLS and helper (002_rls.sql):
- Function public.get_current_user_id() to read current user from:
  - request.jwt.claims.app.user_id or sub, or session GUC app.user_id
- RLS enabled for: auth_users, organizations, memberships, projects, tasks
- Policies implement org membership based access control

Domain (003_domain.sql):
- public.audit_logs
  - id, org_id, project_id, table_name, record_id, action, changed_by, changed_at, old_data, new_data
  - FKs to organizations, projects, auth_users (nullable with set null)
  - Indices on table_name+action, org_id+changed_at
- Public functions re-define helpers if missing to keep idempotency:
  - get_current_user_id() if not present (compatible with 002_rls)
  - audit_log_row_change() for generic auditing
- public.comments
  - id, org_id, task_id, author_id, content, created_at, updated_at
  - FKs: org_id -> organizations, task_id -> tasks, author_id -> auth_users (set null)
  - updated_at trigger + audit trigger
- public.attachments
  - id, org_id, task_id, uploaded_by, filename, content_type, url, size_bytes, created_at, updated_at
  - FKs similar to comments; updated_at trigger + audit trigger
- public.project_github_repos
  - id, org_id, project_id, repo_full_name, installation_id, connected_by, linked_at, created_at, updated_at
  - Unique: (project_id, repo_full_name)
  - updated_at trigger + audit trigger
- public.subscriptions
  - id, org_id, stripe_customer_id, stripe_subscription_id, plan_id, status, current_period_start, current_period_end, canceled_at, created_at, updated_at
  - Unique index ensuring a single active subscription per org
  - updated_at trigger + audit trigger
- public.integrations
  - id, org_id (nullable), user_id (nullable), provider, provider_account_id, access_token, refresh_token, expires_at, scopes, metadata, created_at, updated_at
  - Indices for org/provider and user/provider
  - updated_at trigger + audit trigger
- public.ai_sessions
  - id, org_id, project_id (nullable), created_by, title, model, messages (jsonb), created_at, updated_at
  - Indices
  - updated_at trigger + audit trigger
- tasks reorder utility:
  - Composite type public.task_order_patch (task_id uuid, order_index numeric(12,4))
  - Function public.tasks_reorder_bulk(project_id uuid, status text, patches task_order_patch[]) returns int
    - Bulk updates order_index within a project (+ optional status lane)
    - RLS enforced

Domain RLS (004_domain_rls.sql):
- RLS enabled for domain tables
- Explicit policies per table:
  - comments: org members SELECT; writes by owner/admin or author
  - attachments: org members SELECT; writes by owner/admin or uploader
  - project_github_repos: org members SELECT; owner/admin write
  - subscriptions: org members SELECT; owner/admin write
  - integrations: mixed scope
    - org-scoped: org members SELECT; owner/admin write
    - user-scoped: only the user can SELECT/WRITE
  - ai_sessions: org members SELECT; owner/admin or creator WRITE
  - audit_logs: read-only to org members; no direct write policies (writes via triggers)

--------------------------------------------------------------------------------

5) Troubleshooting failed migrations or ordering

Common issues:
- psql not found
  - Install PostgreSQL client utilities (psql). On Debian/Ubuntu: sudo apt-get install postgresql-client
- Connection failure
  - Verify env vars (POSTGRES_HOST/PORT/DB/USER/PASSWORD)
  - Confirm server is running: ./startup.sh or system service
  - Test connectivity:
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1;"
- Permission errors during migration
  - Ensure the configured user has privileges on the target DB and public schema
  - Re-run ./startup.sh to grant/repair permissions for local dev
- Missing extension pgcrypto
  - 001_init.sql includes: create extension if not exists pgcrypto;
  - Ensure your DB user can create extensions or run that part as a superuser
- RLS policies failing unexpected updates/inserts
  - RLS is strict by design. Ensure your session has a current user id via JWT claims or GUC
  - Set a local session user for testing:
    select set_config('app.user_id','<some-uuid>', false);
  - Then test queries again under psql
- Migration ordering issues
  - Files are sorted lexicographically; ensure you didn’t rename or misnumber files
  - Core order should be:
    001_init.sql -> 002_rls.sql -> 003_domain.sql -> 004_domain_rls.sql
- Re-running migrations
  - Migrations are idempotent-friendly (use “if exists” and safe drops) where possible
  - If a file fails midway, fix the issue and re-run ./migrate.sh
  - For partial object creation, you may need to manually drop/clean before reapplying

Diagnostic tips:
- Run each file manually to identify the failing statement:
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f schema/00X_file.sql
- Check existing policies:
  select * from pg_policies where schemaname='public' order by tablename, policyname;

--------------------------------------------------------------------------------

6) Integration notes for backend

Backend container: collaborative-project-management-platform-19403/backend_api (FastAPI)

Key points:
- RLS by organization membership:
  - The backend must set the authenticated user context for each request so RLS can resolve permissions.
  - In Supabase/PostgREST, this is typically automatic via JWT. In direct Postgres connections, you must supply a JWT or set the session GUC.
- Setting current user in Postgres:
  - Supabase: use the JWT “sub” (or “app.user_id”) claim so get_current_user_id() sees it.
  - Direct DB connections (development/testing):
    - Execute early in request/session:
      select set_config('app.user_id', '<uuid>', false);
    - Or use Postgres settings to inject request.jwt.claims (advanced).
- Active organization context:
  - Policies check memberships by user id (get_current_user_id()) and table relationships (org_id via projects/tasks/comments, etc.)
  - The backend should enforce and pass org_id constraints on queries to avoid cross-org leakage and to align with policy expectations.
- Bulk reordering helper:
  - Use tasks_reorder_bulk(project_id uuid, status text, patches task_order_patch[]):
    - Build an array of (task_id, order_index) patches
    - RLS applies; only rows visible to the acting user will update
- Audit logs:
  - Many tables write audit logs automatically through triggers
  - Reads are allowed to org members; consider exposing filtered audit timelines
- Supabase integration:
  - If using Supabase Auth, align JWT claims with get_current_user_id() (prefers app.user_id, falls back to sub)
  - For non-Supabase environments, make sure to set app.user_id per session or implement a compatible claim injection

Connection strings:
- Example for local dev:
  postgresql://appuser:dbuser123@localhost:5000/myapp
- See db_connection.txt for a ready-to-use psql command when using startup.sh

OpenAPI reference for backend endpoints:
- collaborative-project-management-platform-19403/backend_api/interfaces/openapi.json

--------------------------------------------------------------------------------

Appendix: Useful commands

- Source generated env:
  source db_visualizer/postgres.env

- Test DB connection:
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select version();"

- Apply a single migration:
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f schema/001_init.sql

- View tables:
  \dt public.*

- View policies:
  select * from pg_policies where schemaname='public';

- Set current user (dev/testing):
  select set_config('app.user_id','00000000-0000-0000-0000-000000000000', false);

--------------------------------------------------------------------------------

Support

- If you encounter issues not covered here, please open an issue with logs:
  - Script used (startup.sh/migrate.sh)
  - Full environment values used (mask passwords)
  - Exact error message(s)
  - psql client/server version
