-- 003_domain.sql
-- Domain entities and utility triggers for CollabTask
-- Includes:
--   - comments
--   - attachments
--   - project_github_repos
--   - subscriptions (Stripe)
--   - integrations (OAuth/vendor connections e.g., GitHub)
--   - ai_sessions (history of AI assistant chats)
--   - audit_logs (generic audit trail)
--   - trigger functions: set_updated_at() reuse, audit logging, and task reordering helper
--
-- Conventions:
--  - UUID PKs with gen_random_uuid()
--  - created_at/updated_at timestamps and updated_at trigger
--  - org_id/project_id/task_id foreign keys aligned to 001_init.sql
--  - Idempotent creation using IF NOT EXISTS and safe drops
--  - Works with RLS policies defined in 002_rls.sql

-- Ensure pgcrypto is available for UUID generation
create extension if not exists pgcrypto;

-- Reuse set_updated_at() from 001_init.sql; create if missing
do $$
begin
  if not exists (
    select 1 from pg_proc
    where proname = 'set_updated_at'
      and pg_function_is_visible(oid)
  ) then
    execute $fn$
      create or replace function set_updated_at()
      returns trigger
      language plpgsql
      as $body$
      begin
        new.updated_at = now();
        return new;
      end;
      $body$;
    $fn$;
  end if;
end$$;

-- ============================================================
-- Table: audit_logs
--   Generic audit trail for INSERT/UPDATE/DELETE on auditable tables
-- ============================================================
create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,                         -- Optional org context if available
  project_id uuid,                     -- Optional project context if available
  table_name text not null,
  record_id uuid,                      -- UUID PK of the affected record, when known
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  changed_by uuid,                     -- user id (auth_users.id), when available
  changed_at timestamptz not null default now(),
  old_data jsonb,
  new_data jsonb,
  constraint audit_logs_org_fk
    foreign key (org_id) references public.organizations(id) on delete set null,
  constraint audit_logs_project_fk
    foreign key (project_id) references public.projects(id) on delete set null,
  constraint audit_logs_changed_by_fk
    foreign key (changed_by) references public.auth_users(id) on delete set null
);

create index if not exists idx_audit_logs_table_action on public.audit_logs(table_name, action);
create index if not exists idx_audit_logs_org_changed_at on public.audit_logs(org_id, changed_at);

-- ============================================================
-- Function: get_current_user_id (reused from 002_rls.sql if present)
-- Create a compatible helper here if missing to support audit triggers.
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_proc
    where proname = 'get_current_user_id'
      and pg_function_is_visible(oid)
  ) then
    execute $fn$
      create or replace function public.get_current_user_id()
      returns uuid
      language sql
      stable
      as $body$
        with jwt as (
          select nullif(current_setting('request.jwt.claims', true), '')::jsonb as claims
        )
        select
          coalesce(
            (claims #> '{app,user_id}')::text,
            (claims ->> 'sub'),
            current_setting('app.user_id', true)
          )::uuid
        from jwt;
      $body$;
    $fn$;
  end if;
end$$;

-- ============================================================
-- Function: audit_log_row_change()
--   Generic trigger to write audit_logs for INSERT/UPDATE/DELETE
--   Attempts to infer org_id, project_id, record_id when present in row
-- ============================================================
create or replace function public.audit_log_row_change()
returns trigger
language plpgsql
as $$
declare
  v_action text;
  v_table text := tg_table_name;
  v_changed_by uuid := public.get_current_user_id();
  v_org_id uuid;
  v_project_id uuid;
  v_record_id uuid;
begin
  if tg_op = 'INSERT' then
    v_action := 'INSERT';
    -- Try to extract org/project/record from NEW
    begin v_org_id := (to_jsonb(NEW)->>'org_id')::uuid; exception when others then v_org_id := null; end;
    begin v_project_id := (to_jsonb(NEW)->>'project_id')::uuid; exception when others then v_project_id := null; end;
    begin v_record_id := (to_jsonb(NEW)->>'id')::uuid; exception when others then v_record_id := null; end;

    insert into public.audit_logs(org_id, project_id, table_name, record_id, action, changed_by, old_data, new_data)
    values (v_org_id, v_project_id, v_table, v_record_id, v_action, v_changed_by, null, to_jsonb(NEW));

    return NEW;

  elsif tg_op = 'UPDATE' then
    v_action := 'UPDATE';
    begin v_org_id := coalesce((to_jsonb(NEW)->>'org_id')::uuid, (to_jsonb(OLD)->>'org_id')::uuid); exception when others then v_org_id := null; end;
    begin v_project_id := coalesce((to_jsonb(NEW)->>'project_id')::uuid, (to_jsonb(OLD)->>'project_id')::uuid); exception when others then v_project_id := null; end;
    begin v_record_id := coalesce((to_jsonb(NEW)->>'id')::uuid, (to_jsonb(OLD)->>'id')::uuid); exception when others then v_record_id := null; end;

    insert into public.audit_logs(org_id, project_id, table_name, record_id, action, changed_by, old_data, new_data)
    values (v_org_id, v_project_id, v_table, v_record_id, v_action, v_changed_by, to_jsonb(OLD), to_jsonb(NEW));

    return NEW;

  elsif tg_op = 'DELETE' then
    v_action := 'DELETE';
    begin v_org_id := (to_jsonb(OLD)->>'org_id')::uuid; exception when others then v_org_id := null; end;
    begin v_project_id := (to_jsonb(OLD)->>'project_id')::uuid; exception when others then v_project_id := null; end;
    begin v_record_id := (to_jsonb(OLD)->>'id')::uuid; exception when others then v_record_id := null; end;

    insert into public.audit_logs(org_id, project_id, table_name, record_id, action, changed_by, old_data, new_data)
    values (v_org_id, v_project_id, v_table, v_record_id, v_action, v_changed_by, to_jsonb(OLD), null);

    return OLD;
  end if;

  return null;
end;
$$;

-- ============================================================
-- Table: comments
--  Referenced by RLS in 002_rls.sql
-- ============================================================
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  task_id uuid not null,
  author_id uuid not null,
  content text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint comments_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint comments_task_fk
    foreign key (task_id) references public.tasks(id) on delete cascade,
  constraint comments_author_fk
    foreign key (author_id) references public.auth_users(id) on delete set null
);

create index if not exists idx_comments_task_id on public.comments(task_id);
create index if not exists idx_comments_org_id_created_at on public.comments(org_id, created_at);

-- triggers
drop trigger if exists trg_comments_updated_at on public.comments;
create trigger trg_comments_updated_at
before update on public.comments
for each row
execute function set_updated_at();

drop trigger if exists trg_comments_audit on public.comments;
create trigger trg_comments_audit
after insert or update or delete on public.comments
for each row
execute function public.audit_log_row_change();

-- ============================================================
-- Table: attachments
--   File metadata for task attachments
-- ============================================================
create table if not exists public.attachments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  task_id uuid not null,
  uploaded_by uuid not null,
  filename text not null,
  content_type text,
  url text not null,              -- storage object url/key
  size_bytes bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint attachments_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint attachments_task_fk
    foreign key (task_id) references public.tasks(id) on delete cascade,
  constraint attachments_user_fk
    foreign key (uploaded_by) references public.auth_users(id) on delete set null
);

create index if not exists idx_attachments_task_id on public.attachments(task_id);
create index if not exists idx_attachments_org_id_created_at on public.attachments(org_id, created_at);

drop trigger if exists trg_attachments_updated_at on public.attachments;
create trigger trg_attachments_updated_at
before update on public.attachments
for each row
execute function set_updated_at();

drop trigger if exists trg_attachments_audit on public.attachments;
create trigger trg_attachments_audit
after insert or update or delete on public.attachments
for each row
execute function public.audit_log_row_change();

-- ============================================================
-- Table: project_github_repos
--   Links a project to a GitHub repository
--   Referenced by RLS in 002_rls.sql
-- ============================================================
create table if not exists public.project_github_repos (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  project_id uuid not null,
  repo_full_name text not null,   -- e.g., "owner/repo"
  installation_id bigint,         -- GitHub App installation id if used
  connected_by uuid,              -- who linked it
  linked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint project_github_repos_unique unique (project_id, repo_full_name),
  constraint project_github_repos_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint project_github_repos_project_fk
    foreign key (project_id) references public.projects(id) on delete cascade,
  constraint project_github_repos_user_fk
    foreign key (connected_by) references public.auth_users(id) on delete set null
);

create index if not exists idx_project_github_repos_org_id on public.project_github_repos(org_id);
create index if not exists idx_project_github_repos_project_id on public.project_github_repos(project_id);

drop trigger if exists trg_project_github_repos_updated_at on public.project_github_repos;
create trigger trg_project_github_repos_updated_at
before update on public.project_github_repos
for each row
execute function set_updated_at();

drop trigger if exists trg_project_github_repos_audit on public.project_github_repos;
create trigger trg_project_github_repos_audit
after insert or update or delete on public.project_github_repos
for each row
execute function public.audit_log_row_change();

-- ============================================================
-- Table: subscriptions
--   Stripe subscription info per organization
-- ============================================================
create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  stripe_customer_id text,
  stripe_subscription_id text,
  plan_id text,                  -- internal or Stripe price id
  status text not null default 'inactive',
  current_period_start timestamptz,
  current_period_end timestamptz,
  canceled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subscriptions_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint subscriptions_status_check check (status in ('inactive','trialing','active','past_due','canceled','unpaid'))
);

create unique index if not exists idx_subscriptions_org_unique_active
  on public.subscriptions(org_id)
  where status in ('trialing','active','past_due');

drop trigger if exists trg_subscriptions_updated_at on public.subscriptions;
create trigger trg_subscriptions_updated_at
before update on public.subscriptions
for each row
execute function set_updated_at();

drop trigger if exists trg_subscriptions_audit on public.subscriptions;
create trigger trg_subscriptions_audit
after insert or update or delete on public.subscriptions
for each row
execute function public.audit_log_row_change();

-- ============================================================
-- Table: integrations
--   External service connections (e.g., GitHub OAuth at user or org level)
-- ============================================================
create table if not exists public.integrations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,                    -- may be null for user-level integrations
  user_id uuid,                   -- optional owner
  provider text not null,         -- e.g., 'github', 'slack'
  provider_account_id text,       -- external account id
  access_token text,              -- encrypted/managed externally in production
  refresh_token text,
  expires_at timestamptz,
  scopes text,
  metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint integrations_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint integrations_user_fk
    foreign key (user_id) references public.auth_users(id) on delete cascade
);

create index if not exists idx_integrations_org_provider on public.integrations(org_id, provider);
create index if not exists idx_integrations_user_provider on public.integrations(user_id, provider);

drop trigger if exists trg_integrations_updated_at on public.integrations;
create trigger trg_integrations_updated_at
before update on public.integrations
for each row
execute function set_updated_at();

drop trigger if exists trg_integrations_audit on public.integrations;
create trigger trg_integrations_audit
after insert or update or delete on public.integrations
for each row
execute function public.audit_log_row_change();

-- ============================================================
-- Table: ai_sessions
--   Stores AI assistant chat session metadata and history
-- ============================================================
create table if not exists public.ai_sessions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  project_id uuid,
  created_by uuid not null,
  title text,
  model text,                -- model used
  messages jsonb not null default '[]'::jsonb, -- array of {role, content, timestamp}
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_sessions_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint ai_sessions_project_fk
    foreign key (project_id) references public.projects(id) on delete set null,
  constraint ai_sessions_user_fk
    foreign key (created_by) references public.auth_users(id) on delete set null
);

create index if not exists idx_ai_sessions_org_created_at on public.ai_sessions(org_id, created_at);
create index if not exists idx_ai_sessions_project_id on public.ai_sessions(project_id);

drop trigger if exists trg_ai_sessions_updated_at on public.ai_sessions;
create trigger trg_ai_sessions_updated_at
before update on public.ai_sessions
for each row
execute function set_updated_at();

drop trigger if exists trg_ai_sessions_audit on public.ai_sessions;
create trigger trg_ai_sessions_audit
after insert or update or delete on public.ai_sessions
for each row
execute function public.audit_log_row_change();

-- ============================================================
-- TASK REORDERING SUPPORT (optional utility)
--   Function to bulk update order_index for tasks in a project (and optional status)
--   Accepts: project UUID, optional lane status text, and list of patches {task_id uuid, order_index numeric}
--   Usage from backend can call this via RPC or direct SQL in a transaction.
-- ============================================================

-- Define a composite type for patches if not exists
do $$
begin
  if not exists (select 1 from pg_type where typname = 'task_order_patch') then
    create type public.task_order_patch as (
      task_id uuid,
      order_index numeric(12,4)
    );
  end if;
end$$;

create or replace function public.tasks_reorder_bulk(
  in_project_id uuid,
  in_status text,
  in_patches public.task_order_patch[]
)
returns int
language plpgsql
as $$
declare
  p public.task_order_patch;
  updated_count int := 0;
begin
  if in_patches is null or array_length(in_patches,1) is null then
    return 0;
  end if;

  -- Authorization: rely on RLS in public.tasks as defined in 002_rls.sql
  -- Only rows visible under RLS will be updated.

  foreach p in array in_patches loop
    if in_status is null then
      update public.tasks
         set order_index = p.order_index
       where id = p.task_id
         and project_id = in_project_id;
    else
      update public.tasks
         set order_index = p.order_index
       where id = p.task_id
         and project_id = in_project_id
         and status = in_status;
    end if;

    get diagnostics updated_count = updated_count + row_count;
  end loop;

  return updated_count;
end;
$$;

comment on function public.tasks_reorder_bulk(uuid, text, public.task_order_patch[]) is
'Bulk update order_index for tasks in a project (+optional status lane). Returns number of rows affected. RLS enforced.';

-- End of 003_domain.sql
