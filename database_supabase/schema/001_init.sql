-- 001_init.sql
-- Initial schema for CollabTask core entities (Supabase/Postgres compatible)
-- Includes: auth_users (dev-only), organizations, memberships, projects, tasks
-- Conventions:
--  - UUID primary keys via gen_random_uuid()
--  - created_at/updated_at timestamp columns with trigger to auto-update updated_at
--  - basic uniqueness constraints
--  - explicit foreign keys with ON DELETE behavior
--  - enum-like constraints via CHECKs for role/status/priority
--
-- Note: In Supabase, enable pgcrypto to use gen_random_uuid()

-- Extensions
create extension if not exists pgcrypto;

-- Timestamp trigger function (updates updated_at on row changes)
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ===============================
-- Table: auth_users (dev-only)
-- For local development when Supabase Auth is not used.
-- In production, Supabase Auth manages users in auth schema.
-- ===============================
create table if not exists public.auth_users (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  hashed_password text not null,
  name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- trigger for auth_users
drop trigger if exists trg_auth_users_updated_at on public.auth_users;
create trigger trg_auth_users_updated_at
before update on public.auth_users
for each row
execute function set_updated_at();

-- ===============================
-- Table: organizations
-- ===============================
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizations_owner_fk
    foreign key (owner_id) references public.auth_users(id) on delete restrict
);

-- index: owner_id for quick lookup
create index if not exists idx_organizations_owner_id on public.organizations(owner_id);

-- trigger for organizations
drop trigger if exists trg_organizations_updated_at on public.organizations;
create trigger trg_organizations_updated_at
before update on public.organizations
for each row
execute function set_updated_at();

-- ===============================
-- Table: memberships
-- A user can be in an organization with a role.
-- Unique per (org_id, user_id)
-- ===============================
create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  user_id uuid not null,
  role text not null default 'member',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint memberships_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint memberships_user_fk
    foreign key (user_id) references public.auth_users(id) on delete cascade,
  constraint memberships_unique_user_org unique (org_id, user_id),
  constraint memberships_role_check check (role in ('owner', 'admin', 'member'))
);

create index if not exists idx_memberships_org_id on public.memberships(org_id);
create index if not exists idx_memberships_user_id on public.memberships(user_id);

-- trigger for memberships
drop trigger if exists trg_memberships_updated_at on public.memberships;
create trigger trg_memberships_updated_at
before update on public.memberships
for each row
execute function set_updated_at();

-- ===============================
-- Table: projects
-- ===============================
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  name text not null,
  description text,
  status text not null default 'active',
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint projects_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint projects_created_by_fk
    foreign key (created_by) references public.auth_users(id) on delete set null,
  constraint projects_status_check check (status in ('active', 'archived'))
);

create index if not exists idx_projects_org_id on public.projects(org_id);

-- trigger for projects
drop trigger if exists trg_projects_updated_at on public.projects;
create trigger trg_projects_updated_at
before update on public.projects
for each row
execute function set_updated_at();

-- ===============================
-- Table: tasks
-- ===============================
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  title text not null,
  description text,
  status text not null default 'todo',
  priority text not null default 'medium',
  assignee_id uuid,
  due_date date,
  order_index numeric(12,4) default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tasks_project_fk
    foreign key (project_id) references public.projects(id) on delete cascade,
  constraint tasks_assignee_fk
    foreign key (assignee_id) references public.auth_users(id) on delete set null,
  constraint tasks_status_check check (status in ('todo', 'in_progress', 'blocked', 'done')),
  constraint tasks_priority_check check (priority in ('low', 'medium', 'high', 'urgent'))
);

create index if not exists idx_tasks_project_id on public.tasks(project_id);
create index if not exists idx_tasks_assignee_id on public.tasks(assignee_id);
create index if not exists idx_tasks_project_status on public.tasks(project_id, status);

-- trigger for tasks
drop trigger if exists trg_tasks_updated_at on public.tasks;
create trigger trg_tasks_updated_at
before update on public.tasks
for each row
execute function set_updated_at();

-- ======================================
-- Optional seed roles via check constraints are defined above.
-- Supabase RLS policies will be added in a subsequent migration to enforce org-based access.
-- ======================================

-- End of 001_init.sql
