-- Migration 015: status board config + notes RPCs
-- ================================================================

-- RPC: get status board config (pill colors + lifecycle order)
create or replace function get_status_board_config(p_token text)
returns table(
  execution_priorities jsonb,
  execution_statuses jsonb,
  execution_lifecycle_stages jsonb,
  execution_sponsor_groups jsonb,
  execution_platforms jsonb
)
language sql stable security definer
as $$
  select
    wc.execution_priorities,
    wc.execution_statuses,
    wc.execution_lifecycle_stages,
    wc.execution_sponsor_groups,
    wc.execution_platforms
  from workspace_config wc
  where wc.status_board_token = p_token
    and p_token <> '';
$$;

grant execute on function get_status_board_config(text) to anon;
grant execute on function get_status_board_config(text) to authenticated;

-- RPC: get notes for a project (token-gated, no auth required)
create or replace function get_status_board_notes(p_token text, p_project_id uuid)
returns table(
  id uuid,
  author_name text,
  author_role text,
  body text,
  created_at timestamptz
)
language sql stable security definer
as $$
  select
    pn.id, pn.author_name, pn.author_role, pn.body, pn.created_at
  from project_notes pn
  join projects p on p.id = pn.project_id
  join workspace_config wc on wc.workspace_id = p.workspace_id
  where pn.project_id = p_project_id
    and wc.status_board_token = p_token
    and p_token <> ''
    and p.status = 'Accepted'
    and p.deleted_at is null
  order by pn.created_at desc;
$$;

grant execute on function get_status_board_notes(text, uuid) to anon;
grant execute on function get_status_board_notes(text, uuid) to authenticated;
