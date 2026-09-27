-- ==============================================================================
-- Migration: Corrigir RLS de workspaces/profiles e auto-provisionar usuarios existentes
-- ==============================================================================

-- 1. RLS em quiz.workspace_members (permite ver a si mesmo e aos colegas de workspace)
drop policy if exists "Members can view workspace roster" on quiz.workspace_members;
drop policy if exists "Users can view own memberships" on quiz.workspace_members;

create policy "Users can view own and teammate memberships"
  on quiz.workspace_members for select
  to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1
      from quiz.workspace_members wm
      where wm.workspace_id = workspace_members.workspace_id
        and wm.user_id = auth.uid()
    )
  );

-- 2. RLS em quiz.workspaces (permite ao owner e aos membros visualizarem o workspace)
drop policy if exists "Members can view workspaces" on quiz.workspaces;

create policy "Members can view workspaces"
  on quiz.workspaces for select
  to authenticated
  using (
    owner_id = auth.uid()
    or exists (
      select 1
      from quiz.workspace_members wm
      where wm.workspace_id = workspaces.id
        and wm.user_id = auth.uid()
    )
  );

-- 3. RLS em quiz.profiles (permite ao proprio usuario e aos colegas de workspace visualizarem o perfil)
drop policy if exists "Users can view own profile" on quiz.profiles;
drop policy if exists "Workspace members can view teammate profiles" on quiz.profiles;

create policy "Users can view own and teammate profiles"
  on quiz.profiles for select
  to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1
      from quiz.workspace_members wm_self
      join quiz.workspace_members wm_other
        on wm_self.workspace_id = wm_other.workspace_id
      where wm_self.user_id = auth.uid()
        and wm_other.user_id = profiles.id
    )
  );

-- 4. Auto-provisionar qualquer usuario existente em auth.users no schema quiz
do $$
declare
  u record;
  new_ws_id uuid;
  ws_name text;
  ws_slug text;
begin
  for u in select id, email, raw_user_meta_data from auth.users loop
    -- Garantir perfil
    insert into quiz.profiles (id, email, full_name)
    values (
      u.id,
      coalesce(u.email, ''),
      coalesce(u.raw_user_meta_data ->> 'full_name', '')
    )
    on conflict (id) do update set
      email = excluded.email,
      full_name = coalesce(nullif(excluded.full_name, ''), quiz.profiles.full_name);

    -- Se o usuario nao tem nenhum workspace:
    if not exists (select 1 from quiz.workspace_members where user_id = u.id) then
      ws_name := coalesce(nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''), 'Meu workspace');
      ws_slug := 'workspace-' || substr(replace(u.id::text, '-', ''), 1, 8);

      insert into quiz.workspaces (name, slug, owner_id)
      values (ws_name, ws_slug, u.id)
      on conflict (slug) do nothing
      returning id into new_ws_id;

      if new_ws_id is null then
        select id into new_ws_id from quiz.workspaces where slug = ws_slug limit 1;
      end if;

      if new_ws_id is not null then
        insert into quiz.workspace_members (workspace_id, user_id, role)
        values (new_ws_id, u.id, 'owner')
        on conflict (workspace_id, user_id) do nothing;

        insert into quiz.workspace_subscriptions (
          workspace_id, plan_id, status, current_period_start, current_period_end
        )
        select new_ws_id, ps.default_plan_id, 'active', now(), now() + make_interval(days => ps.trial_days)
        from quiz.platform_settings ps
        where ps.id = 1 and ps.default_plan_id is not null and coalesce(ps.trial_days, 0) > 0
        on conflict (workspace_id) do nothing;
      end if;
    end if;
  end loop;
end $$;

-- 5. Recarregar cache do PostgREST
select pg_notify('pgrst', 'reload schema');
