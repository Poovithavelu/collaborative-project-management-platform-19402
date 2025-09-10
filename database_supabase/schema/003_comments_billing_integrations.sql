-- 003_comments_billing_integrations.sql
-- Purpose: Add comments, attachments, activity logs, subscriptions/billing, and integrations (GitHub, Stripe, OpenAI)
-- Ensures foreign keys, constraints, and row-level security aligned with org membership model.

-- ===============================
-- COMMENTS
-- ===============================
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  task_id uuid,
  author_id uuid not null,
  body text not null,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint comments_project_fk
    foreign key (project_id) references public.projects(id) on delete cascade,
  constraint comments_task_fk
    foreign key (task_id) references public.tasks(id) on delete cascade,
  constraint comments_author_fk
    foreign key (author_id) references public.auth_users(id) on delete set null,
  constraint comments_task_project_consistency
    check (task_id is null or task_id in (select t.id from public.tasks t where t.project_id = project_id))
);

create index if not exists idx_comments_project_id on public.comments(project_id);
create index if not exists idx_comments_task_id on public.comments(task_id);
create index if not exists idx_comments_author_id on public.comments(author_id);

drop trigger if exists trg_comments_updated_at on public.comments;
create trigger trg_comments_updated_at
before update on public.comments
for each row execute function set_updated_at();

-- ATTACHMENTS (files linked to tasks or comments)
create table if not exists public.attachments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  task_id uuid,
  comment_id uuid,
  uploaded_by uuid not null,
  file_name text not null,
  file_type text,
  file_size bigint check (file_size >= 0),
  storage_path text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint attachments_project_fk
    foreign key (project_id) references public.projects(id) on delete cascade,
  constraint attachments_task_fk
    foreign key (task_id) references public.tasks(id) on delete cascade,
  constraint attachments_comment_fk
    foreign key (comment_id) references public.comments(id) on delete cascade,
  constraint attachments_uploaded_by_fk
    foreign key (uploaded_by) references public.auth_users(id) on delete set null,
  constraint attachments_parent_consistency
    check (
      -- must be attached to at least a task or comment
      (task_id is not null or comment_id is not null)
    )
);

create index if not exists idx_attachments_project_id on public.attachments(project_id);
create index if not exists idx_attachments_task_id on public.attachments(task_id);
create index if not exists idx_attachments_comment_id on public.attachments(comment_id);
create index if not exists idx_attachments_uploaded_by on public.attachments(uploaded_by);

drop trigger if exists trg_attachments_updated_at on public.attachments;
create trigger trg_attachments_updated_at
before update on public.attachments
for each row execute function set_updated_at();

-- TASK ACTIVITY LOG (auditing of changes)
create table if not exists public.task_activity (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  task_id uuid not null,
  actor_id uuid,
  action text not null, -- e.g., created, updated, status_changed, comment_added, assigned, priority_changed
  diff jsonb,           -- optional structured change details
  created_at timestamptz not null default now(),
  constraint task_activity_project_fk
    foreign key (project_id) references public.projects(id) on delete cascade,
  constraint task_activity_task_fk
    foreign key (task_id) references public.tasks(id) on delete cascade,
  constraint task_activity_actor_fk
    foreign key (actor_id) references public.auth_users(id) on delete set null,
  constraint task_activity_action_check
    check (action in ('created','updated','status_changed','comment_added','assigned','unassigned','priority_changed','archived','restored','moved'))
);

create index if not exists idx_task_activity_project_task on public.task_activity(project_id, task_id);
create index if not exists idx_task_activity_actor on public.task_activity(actor_id);

-- ===============================
-- BILLING / SUBSCRIPTIONS
-- ===============================
-- ORGANIZATION SUBSCRIPTION (Stripe)
create table if not exists public.org_subscriptions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null unique,
  stripe_customer_id text unique,
  stripe_subscription_id text unique,
  plan text not null default 'free', -- free, pro, business, enterprise
  status text not null default 'inactive', -- inactive, active, past_due, canceled, trialing
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean default false,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint org_subscriptions_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint org_subscriptions_plan_check
    check (plan in ('free','pro','business','enterprise')),
  constraint org_subscriptions_status_check
    check (status in ('inactive','active','past_due','canceled','trialing'))
);

create index if not exists idx_org_subscriptions_org_id on public.org_subscriptions(org_id);
create index if not exists idx_org_subscriptions_status on public.org_subscriptions(status);

drop trigger if exists trg_org_subscriptions_updated_at on public.org_subscriptions;
create trigger trg_org_subscriptions_updated_at
before update on public.org_subscriptions
for each row execute function set_updated_at();

-- INVOICES (Stripe mirror, optional)
create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  stripe_invoice_id text unique,
  amount_due_cents integer not null check (amount_due_cents >= 0),
  amount_paid_cents integer not null default 0 check (amount_paid_cents >= 0),
  currency text not null default 'usd',
  status text not null default 'draft', -- draft, open, paid, uncollectible, void
  hosted_invoice_url text,
  invoice_pdf text,
  period_start timestamptz,
  period_end timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint invoices_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint invoices_status_check
    check (status in ('draft','open','paid','uncollectible','void'))
);

create index if not exists idx_invoices_org_status on public.invoices(org_id, status);

drop trigger if exists trg_invoices_updated_at on public.invoices;
create trigger trg_invoices_updated_at
before update on public.invoices
for each row execute function set_updated_at();

-- ===============================
-- INTEGRATIONS
-- ===============================
-- GitHub integration per org
create table if not exists public.github_integrations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null unique,
  installation_id bigint, -- GitHub App installation id
  repo_full_name text,    -- default repo
  settings jsonb default '{}'::jsonb, -- additional settings (sync rules, labels mapping, etc.)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint github_integrations_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade
);

create index if not exists idx_github_integrations_org on public.github_integrations(org_id);

drop trigger if exists trg_github_integrations_updated_at on public.github_integrations;
create trigger trg_github_integrations_updated_at
before update on public.github_integrations
for each row execute function set_updated_at();

-- OpenAI integration per org
create table if not exists public.openai_integrations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null unique,
  model text default 'gpt-4o-mini',
  settings jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint openai_integrations_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade
);

create index if not exists idx_openai_integrations_org on public.openai_integrations(org_id);

drop trigger if exists trg_openai_integrations_updated_at on public.openai_integrations;
create trigger trg_openai_integrations_updated_at
before update on public.openai_integrations
for each row execute function set_updated_at();

-- Generic webhooks for integrations (e.g., inbound events)
create table if not exists public.integration_webhooks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  source text not null, -- e.g., 'stripe','github'
  event_type text not null,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  status text not null default 'received', -- received, processed, failed
  error_message text,
  constraint integration_webhooks_org_fk
    foreign key (org_id) references public.organizations(id) on delete cascade,
  constraint integration_webhooks_status_check
    check (status in ('received','processed','failed'))
);

create index if not exists idx_integration_webhooks_org on public.integration_webhooks(org_id);
create index if not exists idx_integration_webhooks_source on public.integration_webhooks(source);
create index if not exists idx_integration_webhooks_status on public.integration_webhooks(status);

-- ===============================
-- RLS enablement
-- ===============================
alter table if exists public.comments enable row level security;
alter table if exists public.attachments enable row level security;
alter table if exists public.task_activity enable row level security;
alter table if exists public.org_subscriptions enable row level security;
alter table if exists public.invoices enable row level security;
alter table if exists public.github_integrations enable row level security;
alter table if exists public.openai_integrations enable row level security;
alter table if exists public.integration_webhooks enable row level security;

-- ===============================
-- RLS Policies (org-based)
-- ===============================
do $$
begin
  -- comments
  if exists (select 1 from pg_policies where schemaname='public' and tablename='comments') then
    execute 'drop policy if exists "comments_org_members_read" on public.comments';
    execute 'drop policy if exists "comments_org_members_write" on public.comments';
  end if;

  -- attachments
  if exists (select 1 from pg_policies where schemaname='public' and tablename='attachments') then
    execute 'drop policy if exists "attachments_org_members_read" on public.attachments';
    execute 'drop policy if exists "attachments_org_members_write" on public.attachments';
  end if;

  -- task_activity
  if exists (select 1 from pg_policies where schemaname='public' and tablename='task_activity') then
    execute 'drop policy if exists "task_activity_org_members_read" on public.task_activity';
    execute 'drop policy if exists "task_activity_admin_write" on public.task_activity';
  end if;

  -- org_subscriptions
  if exists (select 1 from pg_policies where schemaname='public' and tablename='org_subscriptions') then
    execute 'drop policy if exists "org_subscriptions_owner_admin_read_write" on public.org_subscriptions';
  end if;

  -- invoices
  if exists (select 1 from pg_policies where schemaname='public' and tablename='invoices') then
    execute 'drop policy if exists "invoices_org_members_read" on public.invoices';
    execute 'drop policy if exists "invoices_owner_admin_write" on public.invoices';
  end if;

  -- github_integrations
  if exists (select 1 from pg_policies where schemaname='public' and tablename='github_integrations') then
    execute 'drop policy if exists "github_integrations_owner_admin_read_write" on public.github_integrations';
  end if;

  -- openai_integrations
  if exists (select 1 from pg_policies where schemaname='public' and tablename='openai_integrations') then
    execute 'drop policy if exists "openai_integrations_owner_admin_read_write" on public.openai_integrations';
  end if;

  -- integration_webhooks
  if exists (select 1 from pg_policies where schemaname='public' and tablename='integration_webhooks') then
    execute 'drop policy if exists "integration_webhooks_owner_admin_read" on public.integration_webhooks';
    execute 'drop policy if exists "integration_webhooks_owner_admin_write" on public.integration_webhooks';
  end if;
end$$;

-- COMMENTS policies: org members of the related project can read; writes for org admins/owners or comment author for updates
create policy "comments_org_members_read"
on public.comments
for select
to public
using (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = comments.project_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "comments_org_members_write"
on public.comments
for all
to public
using (
  -- admins/owners in org of project
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = comments.project_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or
  -- author can update/delete own comment
  comments.author_id = public.get_current_user_id()
)
with check (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = comments.project_id
      and m.user_id = public.get_current_user_id()
  )
);

-- ATTACHMENTS policies: org members read; writes admins/owners or uploader for their own
create policy "attachments_org_members_read"
on public.attachments
for select
to public
using (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = attachments.project_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "attachments_org_members_write"
on public.attachments
for all
to public
using (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = attachments.project_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or attachments.uploaded_by = public.get_current_user_id()
)
with check (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = attachments.project_id
      and m.user_id = public.get_current_user_id()
  )
);

-- TASK_ACTIVITY: org members can read; only admins/owners can insert (system/serverside)
create policy "task_activity_org_members_read"
on public.task_activity
for select
to public
using (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = task_activity.project_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "task_activity_admin_write"
on public.task_activity
for insert
to public
with check (
  exists (
    select 1
    from public.projects p
    join public.memberships m on m.org_id = p.org_id
    where p.id = task_activity.project_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- ORG_SUBSCRIPTIONS: restrict to owner/admin of org
create policy "org_subscriptions_owner_admin_read_write"
on public.org_subscriptions
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = org_subscriptions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = org_subscriptions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- INVOICES: org members read; only admins/owners write
create policy "invoices_org_members_read"
on public.invoices
for select
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = invoices.org_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "invoices_owner_admin_write"
on public.invoices
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = invoices.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = invoices.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- GITHUB_INTEGRATIONS: owner/admin only read/write
create policy "github_integrations_owner_admin_read_write"
on public.github_integrations
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = github_integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = github_integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- OPENAI_INTEGRATIONS: owner/admin only read/write
create policy "openai_integrations_owner_admin_read_write"
on public.openai_integrations
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = openai_integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = openai_integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- INTEGRATION_WEBHOOKS: owner/admin read and write (server-driven)
create policy "integration_webhooks_owner_admin_read"
on public.integration_webhooks
for select
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = integration_webhooks.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

create policy "integration_webhooks_owner_admin_write"
on public.integration_webhooks
for all
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = integration_webhooks.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = integration_webhooks.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- End of 003_comments_billing_integrations.sql
