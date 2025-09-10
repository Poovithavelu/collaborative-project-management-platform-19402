-- 002_rls.sql
-- Purpose: Enable Row Level Security (RLS) and define organization-based access policies
--          for core user-data tables in a Supabase/Postgres-compatible setup.
--
-- Tables covered:
--   - public.auth_users
--   - public.organizations
--   - public.memberships
--   - public.projects
--   - public.tasks
--   - public.comments
--   - public.attachments
--   - public.project_github_repos
--
-- RLS Model:
--   - A user (auth_users.id) can access rows that belong to organizations they are a member of (memberships table).
--   - Access to projects, tasks, comments, attachments is mediated via their org or project relationships.
--   - org owner and admins are considered members via memberships table (001_init.sql enforces relationships).
--
-- Supabase Auth Integration:
--   - Supabase JWT embeds the authenticated user's UUID in a claim. Here we assume it is available at 'app.user_id'.
--   - In Supabase, use: current_setting('request.jwt.claims', true)::jsonb ->> 'sub' or a custom claim if configured.
--   - For local development (no Supabase Auth), a fallback tries:
--       1) request.jwt.claims.app.user_id
--       2) request.jwt.claims.sub
--       3) a GUC 'app.user_id' you can SET per session: e.g., SELECT set_config('app.user_id','<uuid>', false);
--
-- IMPORTANT:
--   - Replace or align the claim extraction logic with your actual Supabase/JWT setup if different.
--
-- Helper function: get_current_user_id()
--   - Returns uuid of the current user from JWT claim or session GUC. NULL if unavailable.

create or replace function public.get_current_user_id()
returns uuid
language sql
stable
as $$
  with jwt as (
    select
      -- Parse the full claims jsonb; returns NULL if no JWT present
      nullif(current_setting('request.jwt.claims', true), '')::jsonb as claims
  )
  select
    coalesce(
      -- Preferred custom claim path: {"app": {"user_id": "<uuid>"}}
      (claims #> '{app,user_id}')::text,
      -- Supabase 'sub' (subject) often matches the user id
      (claims ->> 'sub'),
      -- Local dev/session fallback, allow setting via: select set_config('app.user_id','<uuid>', false);
      current_setting('app.user_id', true)
    )::uuid
  from jwt;
$$;

comment on function public.get_current_user_id is
'Returns the current session user id (uuid) derived from JWT (app.user_id or sub) or from session GUC app.user_id.';

-- ======================================================
-- Enable RLS on all covered tables
-- ======================================================
alter table if exists public.auth_users enable row level security;
alter table if exists public.organizations enable row level security;
alter table if exists public.memberships enable row level security;
alter table if exists public.projects enable row level security;
alter table if exists public.tasks enable row level security;
-- Additional domain entities
alter table if exists public.comments enable row level security;
alter table if exists public.attachments enable row level security;
alter table if exists public.project_github_repos enable row level security;

-- Drop existing policies if re-running migration (idempotent-friendly)
do $$
begin
  -- auth_users
  if exists (select 1 from pg_policies where schemaname='public' and tablename='auth_users') then
    execute 'drop policy if exists "auth_users_select_self" on public.auth_users';
    execute 'drop policy if exists "auth_users_update_self" on public.auth_users';
  end if;

  -- organizations
  if exists (select 1 from pg_policies where schemaname='public' and tablename='organizations') then
    execute 'drop policy if exists "organizations_org_members_read" on public.organizations';
    execute 'drop policy if exists "organizations_owner_admin_write" on public.organizations';
  end if;

  -- memberships
  if exists (select 1 from pg_policies where schemaname='public' and tablename='memberships') then
    execute 'drop policy if exists "memberships_org_members_read" on public.memberships';
    execute 'drop policy if exists "memberships_owner_admin_write" on public.memberships';
  end if;

  -- projects
  if exists (select 1 from pg_policies where schemaname='public' and tablename='projects') then
    execute 'drop policy if exists "projects_org_members_read" on public.projects';
    execute 'drop policy if exists "projects_owner_admin_write" on public.projects';
  end if;

  -- tasks
  if exists (select 1 from pg_policies where schemaname='public' and tablename='tasks') then
    execute 'drop policy if exists "tasks_org_members_read" on public.tasks';
    execute 'drop policy if exists "tasks_org_members_write_assigned_admins" on public.tasks';
  end if;

  -- comments
  if exists (select 1 from pg_policies where schemaname='public' and tablename='comments') then
    execute 'drop policy if exists "comments_org_members_read" on public.comments';
    execute 'drop policy if exists "comments_owner_admin_author_write" on public.comments';
  end if;

  -- attachments
  if exists (select 1 from pg_policies where schemaname='public' and tablename='attachments') then
    execute 'drop policy if exists "attachments_org_members_read" on public.attachments';
    execute 'drop policy if exists "attachments_owner_admin_uploader_write" on public.attachments';
  end if;

  -- project_github_repos
  if exists (select 1 from pg_policies where schemaname='public' and tablename='project_github_repos') then
    execute 'drop policy if exists "repos_org_members_read" on public.project_github_repos';
    execute 'drop policy if exists "repos_owner_admin_write" on public.project_github_repos';
  end if;
end$$;

-- ======================================================
-- auth_users
-- - Only users can read/update their own row
-- ======================================================

create policy "auth_users_select_self"
on public.auth_users
for select
to public
using (id = public.get_current_user_id());

create policy "auth_users_update_self"
on public.auth_users
for update
to public
using (id = public.get_current_user_id())
with check (id = public.get_current_user_id());

-- Example SELECT:
--   select * from public.auth_users; -- returns only your own user row.

-- ======================================================
-- organizations
-- - Visibility to users who are members of the organization
-- - Writes allowed for owner/admin members
-- ======================================================

create policy "organizations_org_members_read"
on public.organizations
for select
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = organizations.id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "organizations_owner_admin_write"
on public.organizations
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = organizations.id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = organizations.id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- Example SELECT:
--   select * from public.organizations; -- returns orgs where you have a membership

-- ======================================================
-- memberships
-- - Members of an org can see membership list
-- - Only owner/admin can modify memberships
-- ======================================================

create policy "memberships_org_members_read"
on public.memberships
for select
to public
using (
  exists (
    select 1
    from public.memberships me
    where me.org_id = memberships.org_id
      and me.user_id = public.get_current_user_id()
  )
);

create policy "memberships_owner_admin_write"
on public.memberships
for all
to public
using (
  exists (
    select 1
    from public.memberships me
    where me.org_id = memberships.org_id
      and me.user_id = public.get_current_user_id()
      and me.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships me
    where me.org_id = memberships.org_id
      and me.user_id = public.get_current_user_id()
      and me.role in ('owner','admin')
  )
);

-- Example SELECT:
--   select * from public.memberships; -- returns memberships from your orgs

-- ======================================================
-- projects
-- - Org members can read projects
-- - Owner/admin can write
-- ======================================================

create policy "projects_org_members_read"
on public.projects
for select
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = projects.org_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "projects_owner_admin_write"
on public.projects
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = projects.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = projects.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- Example SELECT:
--   select * from public.projects; -- returns projects in your orgs

-- ======================================================
-- tasks
-- - Org members of the task's project can read tasks
-- - Writes:
--     * Admins/owners in the org can write all tasks in the org
--     * Additionally, allow the assigned user to update their task (optional, included)
-- ======================================================

create policy "tasks_org_members_read"
on public.tasks
for select
to public
using (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = tasks.project_id
      and m.user_id = public.get_current_user_id()
  )
);

-- Allow admins/owners to write any task in their org, and also assignee can update their own task
create policy "tasks_org_members_write_assigned_admins"
on public.tasks
for all
to public
using (
  -- Admin/owner path
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = tasks.project_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or
  -- Assignee path (for updating their own task)
  public.get_current_user_id() is not null and tasks.assignee_id = public.get_current_user_id()
)
with check (
  -- Ensure new/updated row remains within an org where actor is admin/owner OR actor is assignee
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = tasks.project_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or
  (public.get_current_user_id() is not null and assignee_id = public.get_current_user_id())
);

-- Example SELECT:
--   select * from public.tasks; -- returns tasks from projects in your orgs

-- ======================================================
-- comments
-- Schema expectation (informational):
--   comments(id uuid pk, org_id uuid, task_id uuid, author_id uuid, content text, created_at timestamptz)
--   FK: comments.org_id -> organizations.id, comments.task_id -> tasks.id, comments.author_id -> auth_users.id
-- Policies:
--   - Org members (via task->project->org) can read
--   - Writes allowed for org owner/admin; author may update/delete own comments
-- ======================================================

create policy "comments_org_members_read"
on public.comments
for select
to public
using (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = comments.task_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "comments_owner_admin_author_write"
on public.comments
for all
to public
using (
  -- Admin/owner of org path
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = comments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or
  -- Author path
  (public.get_current_user_id() is not null and comments.author_id = public.get_current_user_id())
)
with check (
  -- Ensure org admin/owner or author continues to satisfy policy after write
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = comments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or
  (public.get_current_user_id() is not null and author_id = public.get_current_user_id())
);

-- ======================================================
-- attachments
-- Schema expectation (informational):
--   attachments(id uuid pk, org_id uuid, task_id uuid, uploaded_by uuid, url text, created_at timestamptz, ...)
-- Policies:
--   - Org members (via task->project->org) can read
--   - Writes allowed for org owner/admin; uploader may update/delete own attachments
-- ======================================================

create policy "attachments_org_members_read"
on public.attachments
for select
to public
using (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = attachments.task_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "attachments_owner_admin_uploader_write"
on public.attachments
for all
to public
using (
  -- Admin/owner of org path
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = attachments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or
  -- Uploader path
  (public.get_current_user_id() is not null and attachments.uploaded_by = public.get_current_user_id())
)
with check (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = attachments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or
  (public.get_current_user_id() is not null and uploaded_by = public.get_current_user_id())
);

-- ======================================================
-- project_github_repos
-- Schema expectation (informational):
--   project_github_repos(id uuid pk, org_id uuid, project_id uuid, repo_full_name text, installed_at timestamptz, ...)
-- Policies:
--   - Org members can read
--   - Owner/admin can write
-- ======================================================

create policy "repos_org_members_read"
on public.project_github_repos
for select
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "repos_owner_admin_write"
on public.project_github_repos
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- Notes:
-- - You may further split INSERT/UPDATE/DELETE policies if finer control is needed.
-- - Consider adding SELECT-only policies for public roles as needed for onboarding flows.
-- - If your Supabase JWT uses a different claim, adjust get_current_user_id() accordingly.

-- End of 002_rls.sql
