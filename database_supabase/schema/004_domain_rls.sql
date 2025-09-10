-- 004_domain_rls.sql
-- Purpose: Enable Row Level Security (RLS) and define org/member model policies
--          for new domain tables added in 003_domain.sql:
--          comments, attachments, project_github_repos, subscriptions,
--          integrations, ai_sessions, audit_logs
--
-- Notes:
--  - Idempotent: uses IF EXISTS and drops pre-existing policies safely.
--  - Relies on helper function public.get_current_user_id() from 002_rls.sql or 003_domain.sql.
--  - Policies mirror the org membership model:
--      * Org members can SELECT relevant rows
--      * Owner/Admin can INSERT/UPDATE/DELETE for org-bound tables
--      * Additional self-write paths where applicable (author/uploader/created_by)
--  - Only reference tables that exist now in schema.

-- Ensure RLS is enabled on target tables (if they exist)
alter table if exists public.comments               enable row level security;
alter table if exists public.attachments            enable row level security;
alter table if exists public.project_github_repos   enable row level security;
alter table if exists public.subscriptions          enable row level security;
alter table if exists public.integrations           enable row level security;
alter table if exists public.ai_sessions            enable row level security;
alter table if exists public.audit_logs             enable row level security;

-- Drop old policies if present (idempotency)
do $$
begin
  -- comments
  if exists (select 1 from pg_policies where schemaname='public' and tablename='comments') then
    execute 'drop policy if exists "comments_org_members_read" on public.comments';
    execute 'drop policy if exists "comments_owner_admin_author_write" on public.comments';
    execute 'drop policy if exists "comments_select" on public.comments';
    execute 'drop policy if exists "comments_insert" on public.comments';
    execute 'drop policy if exists "comments_update" on public.comments';
    execute 'drop policy if exists "comments_delete" on public.comments';
  end if;

  -- attachments
  if exists (select 1 from pg_policies where schemaname='public' and tablename='attachments') then
    execute 'drop policy if exists "attachments_org_members_read" on public.attachments';
    execute 'drop policy if exists "attachments_owner_admin_uploader_write" on public.attachments';
    execute 'drop policy if exists "attachments_select" on public.attachments';
    execute 'drop policy if exists "attachments_insert" on public.attachments';
    execute 'drop policy if exists "attachments_update" on public.attachments';
    execute 'drop policy if exists "attachments_delete" on public.attachments';
  end if;

  -- project_github_repos
  if exists (select 1 from pg_policies where schemaname='public' and tablename='project_github_repos') then
    execute 'drop policy if exists "repos_org_members_read" on public.project_github_repos';
    execute 'drop policy if exists "repos_owner_admin_write" on public.project_github_repos';
    execute 'drop policy if exists "project_github_repos_select" on public.project_github_repos';
    execute 'drop policy if exists "project_github_repos_insert" on public.project_github_repos';
    execute 'drop policy if exists "project_github_repos_update" on public.project_github_repos';
    execute 'drop policy if exists "project_github_repos_delete" on public.project_github_repos';
  end if;

  -- subscriptions
  if exists (select 1 from pg_policies where schemaname='public' and tablename='subscriptions') then
    execute 'drop policy if exists "subscriptions_org_members_read" on public.subscriptions';
    execute 'drop policy if exists "subscriptions_owner_admin_write" on public.subscriptions';
    execute 'drop policy if exists "subscriptions_select" on public.subscriptions';
    execute 'drop policy if exists "subscriptions_insert" on public.subscriptions';
    execute 'drop policy if exists "subscriptions_update" on public.subscriptions';
    execute 'drop policy if exists "subscriptions_delete" on public.subscriptions';
  end if;

  -- integrations
  if exists (select 1 from pg_policies where schemaname='public' and tablename='integrations') then
    execute 'drop policy if exists "integrations_org_members_read" on public.integrations';
    execute 'drop policy if exists "integrations_owner_admin_or_self_write" on public.integrations';
    execute 'drop policy if exists "integrations_select" on public.integrations';
    execute 'drop policy if exists "integrations_insert" on public.integrations';
    execute 'drop policy if exists "integrations_update" on public.integrations';
    execute 'drop policy if exists "integrations_delete" on public.integrations';
  end if;

  -- ai_sessions
  if exists (select 1 from pg_policies where schemaname='public' and tablename='ai_sessions') then
    execute 'drop policy if exists "ai_sessions_org_members_read" on public.ai_sessions';
    execute 'drop policy if exists "ai_sessions_owner_admin_or_creator_write" on public.ai_sessions';
    execute 'drop policy if exists "ai_sessions_select" on public.ai_sessions';
    execute 'drop policy if exists "ai_sessions_insert" on public.ai_sessions';
    execute 'drop policy if exists "ai_sessions_update" on public.ai_sessions';
    execute 'drop policy if exists "ai_sessions_delete" on public.ai_sessions';
  end if;

  -- audit_logs
  if exists (select 1 from pg_policies where schemaname='public' and tablename='audit_logs') then
    execute 'drop policy if exists "audit_logs_org_members_read" on public.audit_logs';
    execute 'drop policy if exists "audit_logs_no_direct_write" on public.audit_logs';
    execute 'drop policy if exists "audit_logs_select" on public.audit_logs';
  end if;
end$$;

-- ===========================================
-- comments
-- Org members (via task->project->org) can SELECT; writes by org owner/admin or author
-- Split into explicit SELECT/INSERT/UPDATE/DELETE for clarity.
-- ===========================================

create policy "comments_select"
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

create policy "comments_insert"
on public.comments
for insert
to public
with check (
  -- either org owner/admin for the related org via task, or the author themselves (self-authoring)
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = comments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and author_id = public.get_current_user_id())
);

create policy "comments_update"
on public.comments
for update
to public
using (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = comments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and comments.author_id = public.get_current_user_id())
)
with check (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = comments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and author_id = public.get_current_user_id())
);

create policy "comments_delete"
on public.comments
for delete
to public
using (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = comments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and comments.author_id = public.get_current_user_id())
);

-- ===========================================
-- attachments
-- Org members can SELECT; writes by org owner/admin or the uploader
-- ===========================================

create policy "attachments_select"
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

create policy "attachments_insert"
on public.attachments
for insert
to public
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
  or (public.get_current_user_id() is not null and uploaded_by = public.get_current_user_id())
);

create policy "attachments_update"
on public.attachments
for update
to public
using (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = attachments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and attachments.uploaded_by = public.get_current_user_id())
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
  or (public.get_current_user_id() is not null and uploaded_by = public.get_current_user_id())
);

create policy "attachments_delete"
on public.attachments
for delete
to public
using (
  exists (
    select 1
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.memberships m on m.org_id = p.org_id
    where t.id = attachments.task_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and attachments.uploaded_by = public.get_current_user_id())
);

-- ===========================================
-- project_github_repos
-- Org members can SELECT; Owner/Admin can write
-- ===========================================

create policy "project_github_repos_select"
on public.project_github_repos
for select
to public
using (
  exists (
    select 1 from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "project_github_repos_insert"
on public.project_github_repos
for insert
to public
with check (
  exists (
    select 1 from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

create policy "project_github_repos_update"
on public.project_github_repos
for update
to public
using (
  exists (
    select 1 from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

create policy "project_github_repos_delete"
on public.project_github_repos
for delete
to public
using (
  exists (
    select 1 from public.memberships m
    where m.org_id = project_github_repos.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- ===========================================
-- subscriptions (org-scoped)
-- Org members can SELECT subscription state; Owner/Admin can write
-- ===========================================

create policy "subscriptions_select"
on public.subscriptions
for select
to public
using (
  exists (
    select 1 from public.memberships m
    where m.org_id = subscriptions.org_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "subscriptions_insert"
on public.subscriptions
for insert
to public
with check (
  exists (
    select 1 from public.memberships m
    where m.org_id = subscriptions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

create policy "subscriptions_update"
on public.subscriptions
for update
to public
using (
  exists (
    select 1 from public.memberships m
    where m.org_id = subscriptions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.org_id = subscriptions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

create policy "subscriptions_delete"
on public.subscriptions
for delete
to public
using (
  exists (
    select 1 from public.memberships m
    where m.org_id = subscriptions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
);

-- ===========================================
-- integrations
-- Mixed scope: may be org-scoped (org_id) or user-scoped (user_id)
-- SELECT:
--   - Org members can see org-scoped integrations
--   - Users can see their own user-scoped integrations
-- WRITE:
--   - Org Owner/Admin can write org-scoped integrations
--   - Users can write their own user-scoped integrations
-- ===========================================

create policy "integrations_select"
on public.integrations
for select
to public
using (
  -- org-scoped visibility for org members
  (org_id is not null and exists (
    select 1
    from public.memberships m
    where m.org_id = integrations.org_id
      and m.user_id = public.get_current_user_id()
  )))
  or
  -- user-scoped visibility for the user
  (org_id is null and user_id is not null and user_id = public.get_current_user_id())
);

create policy "integrations_insert"
on public.integrations
for insert
to public
with check (
  -- org-scoped: only owner/admin
  (org_id is not null and exists (
    select 1
    from public.memberships m
    where m.org_id = integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )))
  or
  -- user-scoped: self only
  (org_id is null and user_id is not null and user_id = public.get_current_user_id())
);

create policy "integrations_update"
on public.integrations
for update
to public
using (
  -- org-scoped: only owner/admin
  (org_id is not null and exists (
    select 1
    from public.memberships m
    where m.org_id = integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )))
  or
  -- user-scoped: self only
  (org_id is null and user_id is not null and integrations.user_id = public.get_current_user_id())
)
with check (
  -- Maintain same constraints after update
  (org_id is not null and exists (
    select 1
    from public.memberships m
    where m.org_id = integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )))
  or
  (org_id is null and user_id is not null and user_id = public.get_current_user_id())
);

create policy "integrations_delete"
on public.integrations
for delete
to public
using (
  -- org-scoped: owner/admin
  (org_id is not null and exists (
    select 1
    from public.memberships m
    where m.org_id = integrations.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )))
  or
  -- user-scoped: self only
  (org_id is null and user_id is not null and integrations.user_id = public.get_current_user_id())
);

-- ===========================================
-- ai_sessions
-- Org members can SELECT; writes by Owner/Admin or session creator (created_by)
-- ===========================================

create policy "ai_sessions_select"
on public.ai_sessions
for select
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = ai_sessions.org_id
      and m.user_id = public.get_current_user_id()
  )
);

create policy "ai_sessions_insert"
on public.ai_sessions
for insert
to public
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = ai_sessions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and created_by = public.get_current_user_id())
);

create policy "ai_sessions_update"
on public.ai_sessions
for update
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = ai_sessions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and ai_sessions.created_by = public.get_current_user_id())
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.org_id = ai_sessions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and created_by = public.get_current_user_id())
);

create policy "ai_sessions_delete"
on public.ai_sessions
for delete
to public
using (
  exists (
    select 1
    from public.memberships m
    where m.org_id = ai_sessions.org_id
      and m.user_id = public.get_current_user_id()
      and m.role in ('owner','admin')
  )
  or (public.get_current_user_id() is not null and ai_sessions.created_by = public.get_current_user_id())
);

-- ===========================================
-- audit_logs
-- Read-only to org members; no direct writes (writes happen via triggers)
-- ===========================================

create policy "audit_logs_select"
on public.audit_logs
for select
to public
using (
  -- expose audit logs to members of the associated org
  org_id is not null and exists (
    select 1 from public.memberships m
    where m.org_id = audit_logs.org_id
      and m.user_id = public.get_current_user_id()
  )
);

-- Do not create INSERT/UPDATE/DELETE policies to prevent direct modifications;
-- audit_logs are managed by triggers (public.audit_log_row_change).

-- End of 004_domain_rls.sql
