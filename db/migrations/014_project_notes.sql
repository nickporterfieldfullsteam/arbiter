-- Migration 014: project_notes table + seed from decision_notes
-- ================================================================

-- 1. Create the table
create table project_notes (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  workspace_id uuid not null references workspaces(id) on delete cascade,
  author_name text not null,
  author_email text,
  author_role text not null default 'pm' check (author_role in ('pm', 'rep', 'system')),
  body text not null,
  created_at timestamptz not null default now()
);

create index idx_project_notes_project on project_notes(project_id, created_at desc);
create index idx_project_notes_workspace on project_notes(workspace_id);

-- 2. RLS
alter table project_notes enable row level security;

-- PMs (workspace members) can read/write notes for their workspace
create policy "Members can read notes"
  on project_notes for select
  using (workspace_id in (
    select workspace_id from workspace_members where user_id = auth.uid()
  ));

create policy "Members can insert notes"
  on project_notes for insert
  with check (workspace_id in (
    select workspace_id from workspace_members where user_id = auth.uid()
  ));

-- Reps can read notes on their own projects
-- Uses auth.email() instead of auth.users to avoid permission errors
create policy "Reps can read notes on own projects"
  on project_notes for select
  using (
    project_id in (
      select id from projects
      where submitter_email = auth.email()
    )
  );

-- Reps can insert notes on their own projects (schema-ready for future use)
create policy "Reps can insert notes on own projects"
  on project_notes for insert
  with check (
    project_id in (
      select id from projects
      where submitter_email = auth.email()
    )
    and author_role = 'rep'
  );

-- 3. Seed existing decision_notes as the first note per project
insert into project_notes (project_id, workspace_id, author_name, author_role, body, created_at)
select
  p.id,
  p.workspace_id,
  'PM',
  'pm',
  p.decision_notes,
  p.updated_at
from projects p
where p.decision_notes is not null
  and p.decision_notes != ''
  and p.deleted_at is null;
