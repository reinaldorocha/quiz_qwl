-- ==============================================================================
-- Migration: Corrigir RLS de workspaces/profiles e auto-provisionar usuarios existentes
-- ==============================================================================

-- 1. RLS em quiz.workspace_members (permite ver a si mesmo e aos membros do mesmo workspace)
drop policy if exists "Members can view workspace roster" on quiz.workspace_members;
drop policy if exists "Users can view own memberships" on quiz.workspace_members;
drop policy if exists "Users can view own and teammate memberships" on quiz.workspace_members;

create policy "Users can view own and teammate memberships"
  on quiz.workspace_members for select
  to authenticated
  using (
    user_id = auth.uid()
    or quiz.is_workspace_member(workspace_id)
  );

-- 2. RLS em quiz.workspaces (permite ao owner e aos membros visualizarem o workspace)
drop policy if exists "Members can view workspaces" on quiz.workspaces;

create policy "Members can view workspaces"
  on quiz.workspaces for select
  to authenticated
  using (
    owner_id = auth.uid()
    or quiz.is_workspace_member(id)
  );

-- 3. RLS em quiz.profiles (permite ver perfis)
drop policy if exists "Users can view own profile" on quiz.profiles;
drop policy if exists "Workspace members can view teammate profiles" on quiz.profiles;
drop policy if exists "Users can view own and teammate profiles" on quiz.profiles;

create policy "Authenticated users can view profiles"
  on quiz.profiles for select
  to authenticated
  using (true);

-- 4. Funcao RPC Security Definer para provisionar workspace sob demanda
create or replace function quiz.create_default_workspace_if_missing(
  p_user_id uuid,
  p_email text,
  p_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  ws_id uuid;
  ws_name text;
  ws_slug text;
begin
  select workspace_id into ws_id
  from quiz.workspace_members
  where user_id = p_user_id
  limit 1;

  if ws_id is not null then
    return ws_id;
  end if;

  insert into quiz.profiles (id, email, full_name)
  values (
    p_user_id,
    coalesce(p_email, ''),
    coalesce(p_name, '')
  )
  on conflict (id) do update set
    email = coalesce(nullif(excluded.email, ''), quiz.profiles.email),
    full_name = coalesce(nullif(excluded.full_name, ''), quiz.profiles.full_name);

  ws_name := coalesce(nullif(trim(p_name), ''), 'Meu workspace');
  ws_slug := 'workspace-' || substr(replace(p_user_id::text, '-', ''), 1, 8);

  insert into quiz.workspaces (name, slug, owner_id)
  values (ws_name, ws_slug, p_user_id)
  on conflict (slug) do nothing
  returning id into ws_id;

  if ws_id is null then
    select id into ws_id from quiz.workspaces where slug = ws_slug limit 1;
  end if;

  if ws_id is not null then
    insert into quiz.workspace_members (workspace_id, user_id, role)
    values (ws_id, p_user_id, 'owner')
    on conflict (workspace_id, user_id) do nothing;

    insert into quiz.workspace_subscriptions (
      workspace_id, plan_id, status, current_period_start, current_period_end
    )
    select ws_id, ps.default_plan_id, 'active', now(), now() + make_interval(days => ps.trial_days)
    from quiz.platform_settings ps
    where ps.id = 1 and ps.default_plan_id is not null and coalesce(ps.trial_days, 0) > 0
    on conflict (workspace_id) do nothing;
  end if;

  return ws_id;
end;
$$;

create or replace function public.create_default_workspace_if_missing(
  p_user_id uuid,
  p_email text,
  p_name text default null
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select quiz.create_default_workspace_if_missing(p_user_id, p_email, p_name);
$$;

grant execute on function quiz.create_default_workspace_if_missing(uuid, text, text) to authenticated, service_role;
grant execute on function public.create_default_workspace_if_missing(uuid, text, text) to authenticated, service_role;

-- 5. Auto-provisionar qualquer usuario existente em auth.users no schema quiz
do $$
declare
  u record;
begin
  for u in select id, email, raw_user_meta_data from auth.users loop
    perform quiz.create_default_workspace_if_missing(
      u.id,
      coalesce(u.email, ''),
      coalesce(u.raw_user_meta_data ->> 'full_name', '')
    );
  end loop;
end $$;

-- 6. Recarregar cache do PostgREST
select pg_notify('pgrst', 'reload schema');

