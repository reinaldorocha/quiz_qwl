-- ==============================================================================
-- Migration: Isolar banco de dados do Quiz no schema dedicado 'quiz'
-- Preserva 100% dos dados existentes e isola completamente o app no PostgreSQL.
-- ==============================================================================

-- 1. Criar o schema dedicado
create schema if not exists quiz;

-- 2. Mover tabelas de public para quiz apenas se nao existirem em quiz
do $$
declare
  tbl text;
begin
  for tbl in select unnest(array[
    'profiles',
    'platform_settings',
    'platform_integrations',
    'platform_integration_events',
    'platform_audit_logs',
    'workspaces',
    'workspace_members',
    'workspace_invitations',
    'plans',
    'workspace_subscriptions',
    'workspace_payments',
    'quizzes',
    'quiz_folders',
    'quiz_custom_domains',
    'quiz_share_links',
    'quiz_daily_metrics',
    'quiz_steps',
    'quiz_widgets',
    'quiz_step_metrics'
  ]) loop
    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = tbl)
       and not exists (select 1 from information_schema.tables where table_schema = 'quiz' and table_name = tbl) then
      execute format('alter table public.%I set schema quiz', tbl);
    end if;
  end loop;
end $$;

-- 3. Funcoes de atualizacao e triggers no schema quiz
create or replace function quiz.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists profiles_updated_at on quiz.profiles;
create trigger profiles_updated_at before update on quiz.profiles for each row execute function quiz.set_updated_at();

drop trigger if exists workspaces_updated_at on quiz.workspaces;
create trigger workspaces_updated_at before update on quiz.workspaces for each row execute function quiz.set_updated_at();

drop trigger if exists quizzes_updated_at on quiz.quizzes;
create trigger quizzes_updated_at before update on quiz.quizzes for each row execute function quiz.set_updated_at();

drop trigger if exists quiz_steps_updated_at on quiz.quiz_steps;
create trigger quiz_steps_updated_at before update on quiz.quiz_steps for each row execute function quiz.set_updated_at();

drop trigger if exists quiz_widgets_updated_at on quiz.quiz_widgets;
create trigger quiz_widgets_updated_at before update on quiz.quiz_widgets for each row execute function quiz.set_updated_at();

drop trigger if exists quiz_custom_domains_updated_at on quiz.quiz_custom_domains;
create trigger quiz_custom_domains_updated_at before update on quiz.quiz_custom_domains for each row execute function quiz.set_updated_at();

drop trigger if exists plans_updated_at on quiz.plans;
create trigger plans_updated_at before update on quiz.plans for each row execute function quiz.set_updated_at();

drop trigger if exists workspace_subscriptions_updated_at on quiz.workspace_subscriptions;
create trigger workspace_subscriptions_updated_at before update on quiz.workspace_subscriptions for each row execute function quiz.set_updated_at();

drop trigger if exists quiz_share_links_updated_at on quiz.quiz_share_links;
create trigger quiz_share_links_updated_at before update on quiz.quiz_share_links for each row execute function quiz.set_updated_at();

drop trigger if exists quiz_folders_updated_at on quiz.quiz_folders;
create trigger quiz_folders_updated_at before update on quiz.quiz_folders for each row execute function quiz.set_updated_at();

drop trigger if exists platform_settings_updated_at on quiz.platform_settings;
create trigger platform_settings_updated_at before update on quiz.platform_settings for each row execute function quiz.set_updated_at();

drop trigger if exists platform_integrations_updated_at on quiz.platform_integrations;
create trigger platform_integrations_updated_at before update on quiz.platform_integrations for each row execute function quiz.set_updated_at();

-- 4. Triggers de integridade de workspace em steps e widgets
create or replace function quiz.set_quiz_step_workspace_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select q.workspace_id into new.workspace_id
  from quiz.quizzes q
  where q.id = new.quiz_id;
  return new;
end;
$$;

drop trigger if exists quiz_steps_set_workspace_id on quiz.quiz_steps;
create trigger quiz_steps_set_workspace_id
  before insert or update of quiz_id on quiz.quiz_steps
  for each row execute function quiz.set_quiz_step_workspace_id();

create or replace function quiz.set_quiz_widget_workspace_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select s.workspace_id into new.workspace_id
  from quiz.quiz_steps s
  where s.id = new.step_id;
  return new;
end;
$$;

drop trigger if exists quiz_widgets_set_workspace_id on quiz.quiz_widgets;
create trigger quiz_widgets_set_workspace_id
  before insert or update of step_id on quiz.quiz_widgets
  for each row execute function quiz.set_quiz_widget_workspace_id();

-- 5. Triggers de seguranca (guards)
create or replace function quiz.guard_workspace_name_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.id is distinct from new.id
    or old.slug is distinct from new.slug
    or old.owner_id is distinct from new.owner_id
    or old.created_at is distinct from new.created_at
  then
    raise exception 'Only workspace name can be updated';
  end if;
  return new;
end;
$$;

drop trigger if exists workspaces_guard_name_update on quiz.workspaces;
create trigger workspaces_guard_name_update
  before update on quiz.workspaces
  for each row execute function quiz.guard_workspace_name_update();

create or replace function quiz.guard_platform_role_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('role', true) in ('service_role', 'postgres')
     or current_user in ('service_role', 'postgres', 'supabase_admin')
  then
    return new;
  end if;

  if new.platform_role is distinct from old.platform_role then
    raise exception 'platform_role só pode ser alterado pelo painel administrativo';
  end if;

  if new.suspended_at is distinct from old.suspended_at
     or new.suspended_reason is distinct from old.suspended_reason
     or new.internal_notes is distinct from old.internal_notes
  then
    raise exception 'campos administrativos são somente leitura para o usuário';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_guard_platform_role on quiz.profiles;
create trigger profiles_guard_platform_role
  before update of platform_role, suspended_at, suspended_reason, internal_notes on quiz.profiles
  for each row execute function quiz.guard_platform_role_update();

-- 6. Funcoes de autorizacao e associacao
create or replace function quiz.is_workspace_member(ws_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from quiz.workspace_members
    where workspace_id = ws_id
      and user_id = auth.uid()
  );
$$;

create or replace function public.is_workspace_member(ws_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select quiz.is_workspace_member(ws_id);
$$;

create or replace function quiz.is_workspace_admin(ws_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from quiz.workspace_members
    where workspace_id = ws_id
      and user_id = auth.uid()
      and role in ('owner', 'admin')
  );
$$;

create or replace function public.is_workspace_admin(ws_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select quiz.is_workspace_admin(ws_id);
$$;

create or replace function quiz.get_user_workspace_role(ws_id uuid)
returns text
language sql
security definer
set search_path = ''
stable
as $$
  select role
  from quiz.workspace_members
  where workspace_id = ws_id
    and user_id = auth.uid()
  limit 1;
$$;

create or replace function public.get_user_workspace_role(ws_id uuid)
returns text
language sql
security definer
set search_path = ''
stable
as $$
  select quiz.get_user_workspace_role(ws_id);
$$;

create or replace function quiz.is_platform_admin()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from quiz.profiles p
    where p.id = auth.uid()
      and p.platform_role = 'admin'
  );
$$;

create or replace function public.is_platform_admin()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select quiz.is_platform_admin();
$$;

create or replace function quiz.is_platform_staff()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from quiz.profiles p
    where p.id = auth.uid()
      and p.platform_role in ('admin', 'support')
  );
$$;

create or replace function public.is_platform_staff()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select quiz.is_platform_staff();
$$;

-- 7. Trigger de novo usuario no auth.users
create or replace function quiz.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  workspace_name text;
  workspace_slug text;
  new_workspace_id uuid;
  v_default_plan_id text;
  v_trial_days integer;
begin
  insert into quiz.profiles (id, email, full_name)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', '')
  )
  on conflict (id) do nothing;

  workspace_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    'Meu workspace'
  );

  workspace_slug := 'workspace-' || substr(replace(new.id::text, '-', ''), 1, 8);

  insert into quiz.workspaces (name, slug, owner_id)
  values (workspace_name, workspace_slug, new.id)
  returning id into new_workspace_id;

  insert into quiz.workspace_members (workspace_id, user_id, role)
  values (new_workspace_id, new.id, 'owner')
  on conflict (workspace_id, user_id) do nothing;

  select ps.default_plan_id, ps.trial_days
    into v_default_plan_id, v_trial_days
  from quiz.platform_settings ps
  where ps.id = 1;

  if v_default_plan_id is not null and coalesce(v_trial_days, 0) > 0 then
    insert into quiz.workspace_subscriptions (
      workspace_id,
      plan_id,
      status,
      current_period_start,
      current_period_end
    )
    values (
      new_workspace_id,
      v_default_plan_id,
      'active',
      now(),
      now() + make_interval(days => v_trial_days)
    )
    on conflict (workspace_id) do nothing;
  end if;

  return new;
exception
  when others then
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function quiz.handle_new_user();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  return new;
end;
$$;

-- 8. Convites de workspace
create or replace function quiz.accept_workspace_invitation(invite_token text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  inv quiz.workspace_invitations%rowtype;
  ws_slug text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;

  select * into inv
  from quiz.workspace_invitations
  where token = invite_token
    and status = 'pending'
    and expires_at > now()
  for update;

  if not found then
    raise exception 'Convite inválido ou expirado';
  end if;

  if not exists (
    select 1
    from quiz.profiles
    where id = auth.uid()
      and lower(email) = lower(inv.email)
  ) then
    raise exception 'O e-mail do convite não corresponde à sua conta';
  end if;

  insert into quiz.workspace_members (workspace_id, user_id, role)
  values (inv.workspace_id, auth.uid(), inv.role)
  on conflict (workspace_id, user_id) do update
    set role = excluded.role;

  update quiz.workspace_invitations
  set status = 'accepted'
  where id = inv.id;

  select slug into ws_slug
  from quiz.workspaces
  where id = inv.workspace_id;

  return ws_slug;
end;
$$;

create or replace function public.accept_workspace_invitation(invite_token text)
returns text
language sql
security definer
set search_path = ''
as $$
  select quiz.accept_workspace_invitation(invite_token);
$$;

-- 9. Analytics de quiz e estatisticas
create or replace function quiz.record_quiz_analytics(
  p_quiz_id uuid,
  p_event text,
  p_step_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date := (timezone('utc', now())::date);
begin
  if p_event not in ('view', 'start', 'complete', 'step_view') then
    raise exception 'evento invalido';
  end if;

  if not exists (
    select 1
    from quiz.quizzes q
    where q.id = p_quiz_id
      and q.status = 'published'
  ) then
    return;
  end if;

  insert into quiz.quiz_daily_metrics (
    quiz_id,
    metric_date,
    views,
    starts,
    completions
  )
  values (
    p_quiz_id,
    v_date,
    case when p_event = 'view' then 1 else 0 end,
    case when p_event = 'start' then 1 else 0 end,
    case when p_event = 'complete' then 1 else 0 end
  )
  on conflict (quiz_id, metric_date) do update set
    views = quiz.quiz_daily_metrics.views + case when p_event = 'view' then 1 else 0 end,
    starts = quiz.quiz_daily_metrics.starts + case when p_event = 'start' then 1 else 0 end,
    completions = quiz.quiz_daily_metrics.completions + case when p_event = 'complete' then 1 else 0 end;

  if p_event = 'step_view' and p_step_id is not null then
    insert into quiz.quiz_step_metrics (quiz_id, step_id, views)
    values (p_quiz_id, p_step_id, 1)
    on conflict (quiz_id, step_id) do update set
      views = quiz.quiz_step_metrics.views + 1;
  end if;
end;
$$;

create or replace function public.record_quiz_analytics(
  p_quiz_id uuid,
  p_event text,
  p_step_id uuid default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  select quiz.record_quiz_analytics(p_quiz_id, p_event, p_step_id);
$$;

create or replace function quiz.get_quiz_statistics(
  p_quiz_id uuid,
  p_days integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from date;
  v_totals record;
  v_daily jsonb;
  v_steps jsonb;
begin
  if auth.uid() is null then
    raise exception 'acesso negado';
  end if;

  if not exists (
    select 1
    from quiz.quizzes q
    join quiz.workspace_members wm on wm.workspace_id = q.workspace_id
    where q.id = p_quiz_id
      and wm.user_id = auth.uid()
  ) then
    raise exception 'acesso negado';
  end if;

  v_from := (timezone('utc', now())::date) - greatest(coalesce(p_days, 30) - 1, 0);

  select
    coalesce(sum(views), 0) as views,
    coalesce(sum(starts), 0) as starts,
    coalesce(sum(completions), 0) as completions
  into v_totals
  from quiz.quiz_daily_metrics
  where quiz_id = p_quiz_id
    and metric_date >= v_from;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'date', metric_date,
        'views', views,
        'starts', starts,
        'completions', completions
      )
      order by metric_date
    ),
    '[]'::jsonb
  )
  into v_daily
  from quiz.quiz_daily_metrics
  where quiz_id = p_quiz_id
    and metric_date >= v_from;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'stepId', step_id,
        'views', views
      )
    ),
    '[]'::jsonb
  )
  into v_steps
  from quiz.quiz_step_metrics
  where quiz_id = p_quiz_id;

  return jsonb_build_object(
    'views', v_totals.views,
    'starts', v_totals.starts,
    'completions', v_totals.completions,
    'conversionRate', case
      when v_totals.views > 0 then round((v_totals.completions::numeric / v_totals.views) * 100, 1)
      else 0
    end,
    'daily', v_daily,
    'stepMetrics', v_steps
  );
end;
$$;

create or replace function public.get_quiz_statistics(
  p_quiz_id uuid,
  p_days integer default 30
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.get_quiz_statistics(p_quiz_id, p_days);
$$;

-- 10. Assinaturas e pagamentos
create or replace function quiz.expire_overdue_subscriptions()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_canceled_count integer;
  v_workspace_ids jsonb;
begin
  with overdue as (
    update quiz.workspace_subscriptions
    set status = 'canceled', updated_at = now()
    where status = 'active'
      and current_period_end is not null
      and current_period_end < now() - interval '2 days'
    returning workspace_id
  )
  select
    count(*)::integer,
    coalesce(jsonb_agg(workspace_id), '[]'::jsonb)
  into v_canceled_count, v_workspace_ids
  from overdue;

  return jsonb_build_object(
    'ok', true,
    'canceled_count', v_canceled_count,
    'workspace_ids', v_workspace_ids,
    'ran_at', now()
  );
end;
$$;

create or replace function public.expire_overdue_subscriptions()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.expire_overdue_subscriptions();
$$;

create or replace function quiz.process_payment_webhook(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace_id uuid;
  v_plan_id text;
  v_provider text;
  v_external_payment_id text;
  v_amount_cents integer;
  v_payment_id uuid;
  v_duplicate boolean := false;
begin
  if coalesce(payload->>'event', '') is distinct from 'payment.paid' then
    raise exception 'evento invalido: esperado payment.paid';
  end if;

  v_workspace_id := (payload->>'workspace_id')::uuid;
  v_plan_id := payload->>'plan_id';
  v_provider := nullif(trim(payload->>'provider'), '');
  v_external_payment_id := nullif(trim(payload->>'external_payment_id'), '');
  v_amount_cents := (payload->>'amount_cents')::integer;

  if v_provider is null or v_external_payment_id is null then
    raise exception 'provider e external_payment_id sao obrigatorios';
  end if;

  if v_amount_cents is null or v_amount_cents <= 0 then
    raise exception 'amount_cents invalido';
  end if;

  if coalesce(trim(payload->>'payment_method'), '') = '' then
    raise exception 'payment_method obrigatorio';
  end if;

  if payload->>'period_start' is null or payload->>'period_end' is null then
    raise exception 'period_start e period_end obrigatorios';
  end if;

  if not exists (
    select 1 from quiz.workspaces w where w.id = v_workspace_id
  ) then
    raise exception 'workspace nao encontrado';
  end if;

  if not exists (
    select 1 from quiz.plans p where p.id = v_plan_id and p.is_active = true
  ) then
    raise exception 'plano nao encontrado ou inativo';
  end if;

  insert into quiz.workspace_payments (
    workspace_id, plan_id, external_payment_id, provider, amount_cents,
    payment_method, period_start, period_end, status, raw_payload
  )
  values (
    v_workspace_id, v_plan_id, v_external_payment_id, v_provider, v_amount_cents,
    trim(payload->>'payment_method'),
    (payload->>'period_start')::timestamptz,
    (payload->>'period_end')::timestamptz,
    'paid', payload
  )
  on conflict (provider, external_payment_id) do nothing
  returning id into v_payment_id;

  v_duplicate := v_payment_id is null;

  insert into quiz.workspace_subscriptions (
    workspace_id, plan_id, status,
    current_period_start, current_period_end, external_subscription_id
  )
  values (
    v_workspace_id, v_plan_id, 'active',
    (payload->>'period_start')::timestamptz,
    (payload->>'period_end')::timestamptz,
    v_external_payment_id
  )
  on conflict (workspace_id) do update set
    plan_id = excluded.plan_id,
    status = 'active',
    current_period_start = excluded.current_period_start,
    current_period_end = excluded.current_period_end,
    external_subscription_id = excluded.external_subscription_id,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'duplicate', v_duplicate,
    'subscription_updated', true,
    'payment_id', v_payment_id
  );
end;
$$;

create or replace function public.process_payment_webhook(payload jsonb)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.process_payment_webhook(payload);
$$;

create or replace function quiz.process_payment_refund(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workspace_id uuid;
  v_payment_id uuid;
  v_refund_external_id text;
  v_refund_payment_id uuid;
  v_original quiz.workspace_payments%rowtype;
  v_raw_payload jsonb;
begin
  if coalesce(payload->>'event', '') is distinct from 'payment.refunded' then
    raise exception 'evento invalido: esperado payment.refunded';
  end if;

  v_workspace_id := (payload->>'workspace_id')::uuid;
  v_payment_id := (payload->>'payment_id')::uuid;

  if v_workspace_id is null or v_payment_id is null then
    raise exception 'workspace_id e payment_id sao obrigatorios';
  end if;

  if not exists (
    select 1 from quiz.workspaces w where w.id = v_workspace_id
  ) then
    raise exception 'workspace nao encontrado';
  end if;

  select *
  into v_original
  from quiz.workspace_payments wp
  where wp.id = v_payment_id
    and wp.workspace_id = v_workspace_id;

  if not found then
    raise exception 'pagamento nao encontrado';
  end if;

  v_refund_external_id := coalesce(
    nullif(trim(payload->>'refund_external_payment_id'), ''),
    'refund_' || v_payment_id::text
  );

  v_raw_payload := payload || jsonb_build_object('original_payment_id', v_payment_id);

  insert into quiz.workspace_payments (
    workspace_id,
    plan_id,
    external_payment_id,
    provider,
    amount_cents,
    payment_method,
    period_start,
    period_end,
    status,
    raw_payload
  ) values (
    v_workspace_id,
    v_original.plan_id,
    v_refund_external_id,
    v_original.provider,
    -abs(v_original.amount_cents),
    v_original.payment_method,
    v_original.period_start,
    v_original.period_end,
    'refunded',
    v_raw_payload
  )
  returning id into v_refund_payment_id;

  update quiz.workspace_subscriptions
  set status = 'canceled', updated_at = now()
  where workspace_id = v_workspace_id
    and status = 'active';

  return jsonb_build_object(
    'ok', true,
    'refund_payment_id', v_refund_payment_id,
    'original_payment_id', v_payment_id,
    'workspace_id', v_workspace_id,
    'status', 'refunded'
  );
end;
$$;

create or replace function public.process_payment_refund(payload jsonb)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.process_payment_refund(payload);
$$;

-- 11. Funcoes de integracao e webhook
create or replace function quiz.purge_old_integration_events()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  delete from quiz.platform_integration_events
  where created_at < now() - interval '90 days';

  get diagnostics v_deleted = row_count;

  return jsonb_build_object(
    'ok', true,
    'deleted_count', v_deleted,
    'ran_at', now()
  );
end;
$$;

create or replace function public.purge_old_integration_events()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.purge_old_integration_events();
$$;

create or replace function quiz.integration_extract_text(
  p_payload jsonb,
  p_path jsonb
)
returns text
language sql
immutable
as $$
  select case
    when p_path is null
      or jsonb_typeof(p_path) <> 'array'
      or jsonb_array_length(p_path) = 0
      then null
    else nullif(
      btrim(p_payload #>> (select array(select jsonb_array_elements_text(p_path)))),
      ''
    )
  end;
$$;

create or replace function public.integration_extract_text(
  p_payload jsonb,
  p_path jsonb
)
returns text
language sql
immutable
as $$
  select quiz.integration_extract_text(p_payload, p_path);
$$;

create or replace function quiz.integration_parse_amount_cents(
  p_raw text,
  p_unit text
)
returns bigint
language plpgsql
immutable
as $$
declare
  v text;
  v_dot integer;
  v_comma integer;
  v_decimal_sep text;
  v_value numeric;
begin
  if p_raw is null then
    return null;
  end if;

  v := btrim(p_raw);
  if v = '' then
    return null;
  end if;

  v := regexp_replace(v, '^[^\d,.-]+', '');
  v := regexp_replace(v, '[^\d,.-]+$', '');
  if v = '' then
    return null;
  end if;

  if coalesce(p_unit, 'major') = 'cents' then
    v := regexp_replace(v, '[^\d-]', '', 'g');
    if v in ('', '-') then
      return null;
    end if;
    return v::bigint;
  end if;

  v_dot := coalesce(nullif(strpos(v, '.'), 0), -1);
  v_comma := coalesce(nullif(strpos(v, ','), 0), -1);

  if v_dot > 0 and v_comma > 0 then
    if v_dot > v_comma then
      v := replace(v, ',', '');
    else
      v := replace(v, '.', '');
      v := replace(v, ',', '.');
    end if;
  elsif v_comma > 0 then
    v := replace(v, ',', '.');
  elsif v_dot > 0 then
    if length(v) - v_dot = 3 and v not like '%.%' and v not like '%-%' then
      v_decimal_sep := '.';
    end if;
  end if;

  begin
    v_value := v::numeric;
  exception when others then
    return null;
  end;

  return round(v_value * 100)::bigint;
end;
$$;

create or replace function public.integration_parse_amount_cents(
  p_raw text,
  p_unit text
)
returns bigint
language sql
immutable
as $$
  select quiz.integration_parse_amount_cents(p_raw, p_unit);
$$;

create or replace function quiz.integration_parse_int(p_raw text)
returns integer
language plpgsql
immutable
as $$
declare
  v text;
begin
  if p_raw is null then
    return null;
  end if;
  v := regexp_replace(btrim(p_raw), '\D', '', 'g');
  if v = '' then
    return null;
  end if;
  return v::integer;
end;
$$;

create or replace function public.integration_parse_int(p_raw text)
returns integer
language sql
immutable
as $$
  select quiz.integration_parse_int(p_raw);
$$;

create or replace function quiz.integration_apply_mapping(
  p_mapping jsonb,
  p_payload jsonb,
  p_kind text default null
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_errors jsonb := '[]'::jsonb;
  v_email text;
  v_full_name text;
  v_external_payment_id text;
  v_payment_method text;
  v_amount_cents bigint;
  v_amount_raw text;
  v_plan jsonb;
  v_plan_mode text;
  v_plan_id text;
  v_plan_refs jsonb := '[]'::jsonb;
  v_access jsonb;
  v_days integer;
  v_filter jsonb;
  v_event_value text;
  v_event_accepted boolean := true;
  v_accepted_list jsonb;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object(
      'errors', jsonb_build_array('Payload vazio ou não é um objeto JSON'),
      'eventAccepted', false
    );
  end if;

  v_filter := coalesce(p_mapping -> 'eventFilter', '{}'::jsonb);
  v_accepted_list := v_filter -> 'acceptedEvents';
  if v_filter -> 'path' is not null
     and jsonb_typeof(v_accepted_list) = 'array'
     and jsonb_array_length(v_accepted_list) > 0
  then
    v_event_value := quiz.integration_extract_text(p_payload, v_filter -> 'path');
    if v_event_value is null then
      v_event_accepted := false;
      v_errors := v_errors || jsonb_build_array('Campo de evento não encontrado no payload');
    else
      select exists (
        select 1
        from jsonb_array_elements_text(v_accepted_list) t(ev)
        where lower(btrim(t.ev)) = lower(btrim(v_event_value))
      ) into v_event_accepted;
    end if;
  end if;

  v_email := lower(nullif(btrim(quiz.integration_extract_text(p_payload, p_mapping -> 'email')), ''));
  if v_email is null then
    v_errors := v_errors || jsonb_build_array('E-mail não encontrado no payload');
  elsif v_email not like '%@%.%' then
    v_errors := v_errors || jsonb_build_array(format('E-mail inválido: "%s"', v_email));
  end if;

  v_full_name := nullif(btrim(quiz.integration_extract_text(p_payload, p_mapping -> 'fullName')), '');
  v_external_payment_id := nullif(btrim(quiz.integration_extract_text(p_payload, p_mapping -> 'externalPaymentId')), '');

  v_amount_raw := quiz.integration_extract_text(p_payload, p_mapping -> 'amountCents');
  if v_amount_raw is not null then
    v_amount_cents := quiz.integration_parse_amount_cents(
      v_amount_raw,
      p_mapping ->> 'amountUnit'
    );
    if v_amount_cents is null then
      v_errors := v_errors || jsonb_build_array(
        format('Valor "%s" não pôde ser convertido para centavos', v_amount_raw)
      );
    end if;
  end if;

  v_payment_method := nullif(btrim(quiz.integration_extract_text(p_payload, p_mapping -> 'paymentMethod')), '');

  v_plan := coalesce(p_mapping -> 'plan', '{}'::jsonb);
  v_plan_mode := coalesce(v_plan ->> 'mode', 'fixed');

  if coalesce(p_kind, 'purchase') = 'refund' then
    v_plan_id := null;
  elsif v_plan_mode = 'fixed' then
    v_plan_id := nullif(btrim(v_plan ->> 'fixedPlanId'), '');
    if v_plan_id is null then
      v_errors := v_errors || jsonb_build_array('Modo de plano fixo sem plano selecionado');
    end if;
  elsif v_plan_mode = 'payload' then
    declare
      v_ref text;
    begin
      v_ref := nullif(btrim(quiz.integration_extract_text(p_payload, v_plan -> 'path')), '');
      if v_ref is not null then
        v_plan_refs := jsonb_build_array(v_ref);
      else
        v_errors := v_errors || jsonb_build_array('Código do produto não encontrado no payload');
      end if;
    end;
  end if;

  v_access := coalesce(p_mapping -> 'access', '{}'::jsonb);
  if coalesce(p_kind, 'purchase') = 'refund' then
    v_days := null;
  elsif coalesce(v_access ->> 'mode', 'fixed') = 'fixed' then
    v_days := nullif(v_access ->> 'fixedDays', '')::integer;
    if v_days is null or v_days <= 0 then
      v_errors := v_errors || jsonb_build_array('Dias de acesso fixos inválidos');
    end if;
  else
    declare
      v_raw_days text;
    begin
      v_raw_days := quiz.integration_extract_text(p_payload, v_access -> 'path');
      v_days := quiz.integration_parse_int(v_raw_days);
      if v_days is null or v_days <= 0 then
        v_errors := v_errors || jsonb_build_array(
          format('Dias de acesso extraídos do payload inválidos: "%s"', coalesce(v_raw_days, ''))
        );
      end if;
    end;
  end if;

  return jsonb_build_object(
    'email', v_email,
    'fullName', v_full_name,
    'externalPaymentId', v_external_payment_id,
    'amountCents', v_amount_cents,
    'paymentMethod', v_payment_method,
    'planMode', v_plan_mode,
    'planId', v_plan_id,
    'planRefs', v_plan_refs,
    'days', v_days,
    'eventAccepted', v_event_accepted,
    'eventValue', v_event_value,
    'errors', v_errors
  );
end;
$$;

create or replace function public.integration_apply_mapping(
  p_mapping jsonb,
  p_payload jsonb,
  p_kind text default null
)
returns jsonb
language sql
immutable
as $$
  select quiz.integration_apply_mapping(p_mapping, p_payload, p_kind);
$$;

create or replace function quiz.integration_grant_access(
  p_event_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event quiz.platform_integration_events%rowtype;
  v_integration quiz.platform_integrations%rowtype;
  v_resolved jsonb;
  v_workspace_id uuid;
  v_plan_id text;
  v_days integer;
  v_amount bigint;
  v_external_payment_id text;
  v_payment_method text;
  v_current_plan text;
  v_current_end timestamptz;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_outcome text;
begin
  select * into v_event
  from quiz.platform_integration_events
  where id = p_event_id;

  if not found then
    return jsonb_build_object('status', 'failed', 'error', 'evento nao encontrado');
  end if;

  select * into v_integration
  from quiz.platform_integrations
  where id = v_event.integration_id;

  v_resolved := v_event.resolved;
  v_plan_id := v_resolved ->> 'resolvedPlanId';
  v_days := (v_resolved ->> 'days')::integer;
  v_amount := nullif(v_resolved ->> 'amountCents', '')::bigint;
  v_external_payment_id := v_resolved ->> 'externalPaymentId';
  v_payment_method := coalesce(nullif(v_resolved ->> 'paymentMethod', ''), 'externo');

  select w.id into v_workspace_id
  from quiz.workspaces w
  where w.owner_id = p_user_id
  order by w.created_at asc
  limit 1;

  if v_workspace_id is null then
    update quiz.platform_integration_events
       set status = 'failed',
           error_message = 'Usuário sem workspace próprio',
           processed_at = now()
     where id = p_event_id;
    return jsonb_build_object('status', 'failed', 'error', 'usuario sem workspace');
  end if;

  if v_days is null or v_days <= 0 then
    update quiz.platform_integration_events
       set status = 'failed',
           error_message = 'Dias de acesso não resolvidos',
           processed_at = now()
     where id = p_event_id;
    return jsonb_build_object('status', 'failed', 'error', 'dias invalidos');
  end if;

  if v_plan_id is null then
    update quiz.platform_integration_events
       set status = 'failed',
           error_message = 'Plano não resolvido',
           processed_at = now()
     where id = p_event_id;
    return jsonb_build_object('status', 'failed', 'error', 'plano nao resolvido');
  end if;

  select plan_id, current_period_end
    into v_current_plan, v_current_end
  from quiz.workspace_subscriptions
  where workspace_id = v_workspace_id;

  v_period_start := now();
  if v_current_plan is not distinct from v_plan_id then
    v_period_end := greatest(coalesce(v_current_end, now()), now())
                    + make_interval(days => v_days);
  else
    v_period_end := now() + make_interval(days => v_days);
  end if;

  if v_amount is not null and v_amount > 0 and v_external_payment_id is not null then
    perform quiz.process_payment_webhook(jsonb_build_object(
      'event', 'payment.paid',
      'workspace_id', v_workspace_id,
      'plan_id', v_plan_id,
      'provider', v_integration.provider_slug,
      'external_payment_id', v_external_payment_id,
      'amount_cents', v_amount,
      'payment_method', v_payment_method,
      'period_start', v_period_start,
      'period_end', v_period_end
    ));
    v_outcome := 'assinatura e pagamento registrados';
  else
    insert into quiz.workspace_subscriptions (
      workspace_id, plan_id, status,
      current_period_start, current_period_end, external_subscription_id
    )
    values (
      v_workspace_id, v_plan_id, 'active',
      v_period_start, v_period_end, v_external_payment_id
    )
    on conflict (workspace_id) do update set
      plan_id = excluded.plan_id,
      status = 'active',
      current_period_start = excluded.current_period_start,
      current_period_end = excluded.current_period_end,
      external_subscription_id = coalesce(
        excluded.external_subscription_id,
        quiz.workspace_subscriptions.external_subscription_id
      ),
      updated_at = now();

    v_outcome := 'assinatura concedida sem registro de pagamento';
  end if;

  update quiz.platform_integration_events
     set status = 'processed',
         outcome = v_outcome,
         workspace_id = v_workspace_id,
         error_message = null,
         processed_at = now()
   where id = p_event_id;

  return jsonb_build_object(
    'status', 'done',
    'event_id', p_event_id,
    'workspace_id', v_workspace_id,
    'plan_id', v_plan_id,
    'period_end', v_period_end,
    'outcome', v_outcome
  );
end;
$$;

create or replace function public.integration_grant_access(
  p_event_id uuid,
  p_user_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.integration_grant_access(p_event_id, p_user_id);
$$;

create or replace function quiz.integration_finalize_purchase(
  p_event_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return quiz.integration_grant_access(p_event_id, p_user_id);
exception when others then
  update quiz.platform_integration_events
     set status = 'failed',
         error_message = sqlerrm,
         processed_at = now()
   where id = p_event_id;
  return jsonb_build_object('status', 'failed', 'error', sqlerrm);
end;
$$;

create or replace function public.integration_finalize_purchase(
  p_event_id uuid,
  p_user_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.integration_finalize_purchase(p_event_id, p_user_id);
$$;

create or replace function quiz.integration_mark_failed(
  p_event_id uuid,
  p_message text
)
returns void
language sql
security definer
set search_path = ''
as $$
  update quiz.platform_integration_events
     set status = 'failed',
         error_message = left(coalesce(p_message, 'erro desconhecido'), 500),
         processed_at = now()
   where id = p_event_id;
$$;

create or replace function public.integration_mark_failed(
  p_event_id uuid,
  p_message text
)
returns void
language sql
security definer
set search_path = ''
as $$
  select quiz.integration_mark_failed(p_event_id, p_message);
$$;

create or replace function quiz.integration_ingest_event(
  p_token text,
  p_payload jsonb,
  p_source_ip text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_integration quiz.platform_integrations%rowtype;
  v_event_id uuid;
  v_existing quiz.platform_integration_events%rowtype;
  v_event_key text;
  v_recent integer;
  v_resolved jsonb;
  v_errors jsonb;
  v_plan_id text;
  v_user_id uuid;
  v_email text;
  v_external_payment_id text;
  v_workspace_id uuid;
  v_payment_id uuid;
  v_pending_refund boolean;
begin
  select * into v_integration
  from quiz.platform_integrations
  where token = p_token;

  if not found then
    return jsonb_build_object('status', 'unknown_token');
  end if;

  select count(*) into v_recent
  from quiz.platform_integration_events
  where integration_id = v_integration.id
    and created_at > now() - interval '1 minute';

  if v_recent > 300 then
    return jsonb_build_object('status', 'rate_limited');
  end if;

  v_event_key := nullif(btrim(
    quiz.integration_extract_text(p_payload, v_integration.field_mapping -> 'externalPaymentId')
  ), '');

  if v_event_key is null then
    v_event_key := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex');
  end if;

  select * into v_existing
  from quiz.platform_integration_events
  where integration_id = v_integration.id
    and event_key = v_event_key;

  if found then
    if v_existing.status = 'processed' then
      return jsonb_build_object(
        'status', 'duplicate',
        'event_id', v_existing.id
      );
    end if;

    v_event_id := v_existing.id;

    update quiz.platform_integration_events
       set payload = p_payload,
           status = 'captured',
           outcome = null,
           error_message = null,
           source_ip = coalesce(p_source_ip, source_ip),
           processed_at = null
     where id = v_event_id;
  else
    insert into quiz.platform_integration_events (
      integration_id, event_key, payload, status, source_ip
    )
    values (
      v_integration.id, v_event_key, p_payload, 'captured', p_source_ip
    )
    returning id into v_event_id;
  end if;

  begin
    if not v_integration.enabled
       or v_integration.field_mapping = '{}'::jsonb
       or v_integration.field_mapping is null
    then
      update quiz.platform_integration_events
         set outcome = case
               when v_integration.field_mapping = '{}'::jsonb
                 or v_integration.field_mapping is null
               then 'Evento capturado para mapeamento'
               else 'Integração desativada'
             end
       where id = v_event_id;

      return jsonb_build_object('status', 'captured', 'event_id', v_event_id);
    end if;

    v_resolved := quiz.integration_apply_mapping(
      v_integration.field_mapping, p_payload, v_integration.kind
    );

    if not (v_resolved ->> 'eventAccepted')::boolean then
      update quiz.platform_integration_events
         set status = 'ignored',
             resolved = v_resolved,
             outcome = format(
               'Evento "%s" fora da lista aceita por esta integração',
               coalesce(v_resolved ->> 'eventValue', 'sem tipo')
             ),
             processed_at = now()
       where id = v_event_id;

      return jsonb_build_object('status', 'ignored', 'event_id', v_event_id);
    end if;

    v_errors := v_resolved -> 'errors';
    if jsonb_array_length(coalesce(v_errors, '[]'::jsonb)) > 0 then
      update quiz.platform_integration_events
         set status = 'failed',
             resolved = v_resolved,
             error_message = (
               select string_agg(value, '; ')
               from jsonb_array_elements_text(v_errors)
             ),
             processed_at = now()
       where id = v_event_id;

      return jsonb_build_object('status', 'failed', 'event_id', v_event_id);
    end if;

    v_email := v_resolved ->> 'email';
    v_external_payment_id := v_resolved ->> 'externalPaymentId';

    -- Reembolso
    if v_integration.kind = 'refund' then
      if v_external_payment_id is not null then
        select id, workspace_id into v_payment_id, v_workspace_id
        from quiz.workspace_payments
        where provider = v_integration.provider_slug
          and external_payment_id = v_external_payment_id
        limit 1;

        if v_payment_id is null then
          select id, workspace_id into v_payment_id, v_workspace_id
          from quiz.workspace_payments
          where external_payment_id = v_external_payment_id
          order by created_at desc
          limit 1;
        end if;
      end if;

      if v_workspace_id is null and v_email is not null then
        select w.id into v_workspace_id
        from auth.users u
        join quiz.workspaces w on w.owner_id = u.id
        where lower(u.email) = v_email
        order by w.created_at asc
        limit 1;
      end if;

      if v_workspace_id is null then
        update quiz.platform_integration_events
           set status = 'ignored',
               resolved = v_resolved,
               outcome = 'Nenhuma compra encontrada para este reembolso',
               processed_at = now()
         where id = v_event_id;

        return jsonb_build_object('status', 'ignored', 'event_id', v_event_id);
      end if;

      if v_payment_id is not null then
        update quiz.workspace_payments
           set status = 'refunded'
         where id = v_payment_id;

        update quiz.workspace_subscriptions
           set status = 'canceled', updated_at = now()
         where workspace_id = v_workspace_id
           and external_subscription_id = v_external_payment_id;

        if not found then
          update quiz.platform_integration_events
             set status = 'ignored',
                 resolved = v_resolved,
                 workspace_id = v_workspace_id,
                 outcome = 'Pagamento estornado, mas a assinatura vigente é de outra compra',
                 processed_at = now()
           where id = v_event_id;

          return jsonb_build_object('status', 'ignored', 'event_id', v_event_id);
        end if;
      else
        update quiz.workspace_subscriptions
           set status = 'canceled', updated_at = now()
         where workspace_id = v_workspace_id;
      end if;

      update quiz.platform_integration_events
         set status = 'processed',
             resolved = v_resolved,
             workspace_id = v_workspace_id,
             outcome = 'Acesso removido',
             processed_at = now()
       where id = v_event_id;

      return jsonb_build_object(
        'status', 'done',
        'event_id', v_event_id,
        'workspace_id', v_workspace_id
      );
    end if;

    -- Compra
    select exists (
      select 1
      from quiz.platform_integration_events e
      join quiz.platform_integrations i on i.id = e.integration_id
      where i.kind = 'refund'
        and e.event_key = v_external_payment_id
        and e.status in ('ignored', 'failed')
    ) into v_pending_refund;

    if v_pending_refund then
      update quiz.platform_integration_events
         set status = 'ignored',
             resolved = v_resolved,
             outcome = 'Existe reembolso pendente para este pedido — acesso não concedido',
             processed_at = now()
       where id = v_event_id;

      return jsonb_build_object('status', 'ignored', 'event_id', v_event_id);
    end if;

    if v_resolved ->> 'planId' is not null then
      select id into v_plan_id
      from quiz.plans
      where id = v_resolved ->> 'planId' and is_active = true;
    else
      select p.id into v_plan_id
      from quiz.plans p
      where p.is_active = true
        and exists (
          select 1
          from jsonb_array_elements_text(v_resolved -> 'planRefs') t(ref)
          where lower(btrim(t.ref)) = any (
            select lower(er) from unnest(p.external_references) er
          )
        )
      order by p.sort_order asc
      limit 1;
    end if;

    if v_plan_id is null then
      update quiz.platform_integration_events
         set status = 'failed',
             resolved = v_resolved,
             error_message = format(
               'Nenhum plano ativo corresponde a %s',
               coalesce(v_resolved ->> 'planId', v_resolved ->> 'planRefs')
             ),
             processed_at = now()
       where id = v_event_id;

      return jsonb_build_object('status', 'failed', 'event_id', v_event_id);
    end if;

    v_resolved := v_resolved || jsonb_build_object('resolvedPlanId', v_plan_id);

    update quiz.platform_integration_events
       set resolved = v_resolved
     where id = v_event_id;

    select u.id into v_user_id
    from auth.users u
    where lower(u.email) = v_email
    order by u.created_at asc
    limit 1;

    if v_user_id is null then
      return jsonb_build_object(
        'status', 'needs_user',
        'event_id', v_event_id,
        'email', v_email,
        'full_name', v_resolved ->> 'fullName',
        'password', v_integration.default_password
      );
    end if;

    return quiz.integration_grant_access(v_event_id, v_user_id);

  exception when others then
    update quiz.platform_integration_events
       set status = 'failed',
           error_message = left(sqlstate || ': ' || sqlerrm, 500),
           processed_at = now()
     where id = v_event_id;

    return jsonb_build_object(
      'status', 'failed',
      'event_id', v_event_id,
      'error', sqlerrm
    );
  end;
end;
$$;

create or replace function public.integration_ingest_event(
  p_token text,
  p_payload jsonb,
  p_source_ip text default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.integration_ingest_event(p_token, p_payload, p_source_ip);
$$;

create or replace function quiz.integration_reprocess_event(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event quiz.platform_integration_events%rowtype;
  v_token text;
begin
  select * into v_event
  from quiz.platform_integration_events
  where id = p_event_id;

  if not found then
    return jsonb_build_object('status', 'failed', 'error', 'evento nao encontrado');
  end if;

  select token into v_token
  from quiz.platform_integrations
  where id = v_event.integration_id;

  update quiz.platform_integration_events
     set status = 'captured', outcome = null, error_message = null, processed_at = null
   where id = p_event_id;

  return quiz.integration_ingest_event(v_token, v_event.payload, v_event.source_ip);
end;
$$;

create or replace function public.integration_reprocess_event(p_event_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select quiz.integration_reprocess_event(p_event_id);
$$;

-- 12. Storage Policies para quiz-assets
drop policy if exists "Workspace members can read quiz assets" on storage.objects;
drop policy if exists "Workspace members can upload quiz assets" on storage.objects;
drop policy if exists "Workspace members can update quiz assets" on storage.objects;
drop policy if exists "Workspace members can delete quiz assets" on storage.objects;

create policy "Workspace members can read quiz assets"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'quiz-assets'
    and exists (
      select 1
      from quiz.workspace_members wm
      where wm.workspace_id = ((storage.foldername(name))[1])::uuid
        and wm.user_id = auth.uid()
    )
  );

create policy "Workspace members can upload quiz assets"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'quiz-assets'
    and exists (
      select 1
      from quiz.workspace_members wm
      where wm.workspace_id = ((storage.foldername(name))[1])::uuid
        and wm.user_id = auth.uid()
    )
  );

create policy "Workspace members can update quiz assets"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'quiz-assets'
    and exists (
      select 1
      from quiz.workspace_members wm
      where wm.workspace_id = ((storage.foldername(name))[1])::uuid
        and wm.user_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'quiz-assets'
    and exists (
      select 1
      from quiz.workspace_members wm
      where wm.workspace_id = ((storage.foldername(name))[1])::uuid
        and wm.user_id = auth.uid()
    )
  );

create policy "Workspace members can delete quiz assets"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'quiz-assets'
    and exists (
      select 1
      from quiz.workspace_members wm
      where wm.workspace_id = ((storage.foldername(name))[1])::uuid
        and wm.user_id = auth.uid()
    )
  );

-- 13. Concessao de permissoes no schema quiz
do $$
declare
  r text;
begin
  for r in select unnest(array['postgres', 'anon', 'authenticated', 'service_role', 'authenticator', 'supabase_admin', 'dashboard_user']) loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('grant usage on schema quiz to %I', r);
      execute format('grant all privileges on all tables in schema quiz to %I', r);
      execute format('grant all privileges on all sequences in schema quiz to %I', r);
      execute format('grant all privileges on all routines in schema quiz to %I', r);
      execute format('alter default privileges in schema quiz grant all on tables to %I', r);
      execute format('alter default privileges in schema quiz grant all on sequences to %I', r);
      execute format('alter default privileges in schema quiz grant all on routines to %I', r);
    end if;
  end loop;
end $$;

-- 14. Least privilege para funcoes sensiveis
revoke all on function quiz.set_updated_at() from anon, authenticated, public;
revoke all on function quiz.handle_new_user() from anon, authenticated, public;
revoke all on function quiz.set_quiz_step_workspace_id() from anon, authenticated, public;
revoke all on function quiz.set_quiz_widget_workspace_id() from anon, authenticated, public;
revoke all on function quiz.guard_workspace_name_update() from anon, authenticated, public;
revoke all on function quiz.guard_platform_role_update() from anon, authenticated, public;

revoke execute on function quiz.is_platform_admin() from anon;
revoke execute on function quiz.is_platform_staff() from anon;
grant execute on function quiz.is_platform_admin() to authenticated, service_role;
grant execute on function quiz.is_platform_staff() to authenticated, service_role;
grant execute on function public.is_platform_admin() to authenticated, service_role;
grant execute on function public.is_platform_staff() to authenticated, service_role;

revoke execute on function quiz.is_workspace_member(uuid) from anon;
revoke execute on function quiz.is_workspace_admin(uuid) from anon;
revoke execute on function quiz.get_user_workspace_role(uuid) from anon;
grant execute on function quiz.is_workspace_member(uuid) to authenticated, service_role;
grant execute on function quiz.is_workspace_admin(uuid) to authenticated, service_role;
grant execute on function quiz.get_user_workspace_role(uuid) to authenticated, service_role;
grant execute on function public.is_workspace_member(uuid) to authenticated, service_role;
grant execute on function public.is_workspace_admin(uuid) to authenticated, service_role;
grant execute on function public.get_user_workspace_role(uuid) to authenticated, service_role;

revoke execute on function quiz.accept_workspace_invitation(text) from anon;
grant execute on function quiz.accept_workspace_invitation(text) to authenticated, service_role;
grant execute on function public.accept_workspace_invitation(text) to authenticated, service_role;

grant execute on function quiz.record_quiz_analytics(uuid, text, uuid) to anon, authenticated, service_role;
grant execute on function public.record_quiz_analytics(uuid, text, uuid) to anon, authenticated, service_role;

revoke execute on function quiz.get_quiz_statistics(uuid, integer) from anon;
grant execute on function quiz.get_quiz_statistics(uuid, integer) to authenticated, service_role;
grant execute on function public.get_quiz_statistics(uuid, integer) to authenticated, service_role;

revoke all on function quiz.expire_overdue_subscriptions() from anon, authenticated, public;
grant execute on function quiz.expire_overdue_subscriptions() to service_role;
grant execute on function public.expire_overdue_subscriptions() to service_role;

revoke all on function quiz.process_payment_webhook(jsonb) from anon, authenticated, public;
grant execute on function quiz.process_payment_webhook(jsonb) to service_role;
grant execute on function public.process_payment_webhook(jsonb) to service_role;

revoke all on function quiz.process_payment_refund(jsonb) from anon, authenticated, public;
grant execute on function quiz.process_payment_refund(jsonb) to service_role;
grant execute on function public.process_payment_refund(jsonb) to service_role;

revoke all on function quiz.purge_old_integration_events() from anon, authenticated, public;
grant execute on function quiz.purge_old_integration_events() to service_role;
grant execute on function public.purge_old_integration_events() to service_role;

revoke all on function quiz.integration_grant_access(uuid, uuid) from anon, authenticated, public;
revoke all on function quiz.integration_finalize_purchase(uuid, uuid) from anon, authenticated, public;
revoke all on function quiz.integration_mark_failed(uuid, text) from anon, authenticated, public;
revoke all on function quiz.integration_ingest_event(text, jsonb, text) from anon, authenticated, public;
revoke all on function quiz.integration_reprocess_event(uuid) from anon, authenticated, public;

grant execute on function quiz.integration_finalize_purchase(uuid, uuid) to service_role;
grant execute on function quiz.integration_mark_failed(uuid, text) to service_role;
grant execute on function quiz.integration_ingest_event(text, jsonb, text) to service_role;
grant execute on function quiz.integration_reprocess_event(uuid) to service_role;
grant execute on function quiz.integration_apply_mapping(jsonb, jsonb, text) to service_role;

grant execute on function public.integration_finalize_purchase(uuid, uuid) to service_role;
grant execute on function public.integration_mark_failed(uuid, text) to service_role;
grant execute on function public.integration_ingest_event(text, jsonb, text) to service_role;
grant execute on function public.integration_reprocess_event(uuid) to service_role;
grant execute on function public.integration_apply_mapping(jsonb, jsonb, text) to service_role;

-- 15. Anon restrito para tabela quizzes
revoke select on quiz.quizzes from anon;
grant select (
  id,
  workspace_id,
  title,
  slug,
  status,
  created_by,
  created_at,
  updated_at,
  published_at,
  published_content
) on quiz.quizzes to anon;

-- 16. Recarregar cache do PostgREST
select pg_notify('pgrst', 'reload schema');
