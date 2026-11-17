-- Play2Win Withdrawal Rejection Reason Popup + User Visibility (Supabase SQL Migration)
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Includes:
--   1. Adds `rejection_reason` column to your withdrawal requests table + audit table `withdrawal_rejection_reasons`
--   2. `admin_reject_withdrawal(p_token, p_request_id, p_reason)` RPC (requires non-empty reason, refunds coins via `admin_review_withdrawal`)
--   3. `my_withdrawal_requests_v2(p_token)` and `admin_list_withdrawal_requests_v2(p_token)` returning `rejection_reason`

create table if not exists public.withdrawal_rejection_reasons (
  request_id bigint primary key,
  user_id text not null,
  reason text not null,
  rejected_by text,
  created_at timestamptz not null default now()
);

create or replace function public._p2w_wdr_detect_schema()
returns table(
  users_table text,
  balance_col text,
  sessions_table text,
  coin_log_table text,
  withdrawals_table text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_users_tbl text;
  v_bal_col text;
  v_sessions_tbl text;
  v_coin_log_tbl text;
  v_withdrawals_tbl text;
begin
  select format('%I.%I', t.table_schema, t.table_name),
         max(case when c.column_name in ('balance','coins','credits') then c.column_name end)
  into v_users_tbl, v_bal_col
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('referral_settings','user_referrals','referral_events','email_auth_accounts','aviator_rounds','aviator_global_rounds','aviator_bets','number_game_admin_overrides','withdrawal_rejection_reasons')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'id')
     and bool_or(c.column_name in ('balance','coins','credits'))
  order by (t.table_schema = 'public') desc, (t.table_name in ('app_users','users')) desc, t.table_name
  limit 1;

  select format('%I.%I', t.table_schema, t.table_name)
  into v_sessions_tbl
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'token')
     and bool_or(c.column_name = 'user_id')
  order by (t.table_schema = 'public') desc, (t.table_name in ('app_sessions','sessions')) desc, t.table_name
  limit 1;

  select format('%I.%I', t.table_schema, t.table_name)
  into v_coin_log_tbl
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('referral_settings','user_referrals','referral_events','withdrawal_rejection_reasons')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'user_id')
     and bool_or(c.column_name = 'amount')
     and bool_or(c.column_name = 'created_at')
     and not bool_or(c.column_name in ('target','utr','upi_id','round','payout'))
  order by (t.table_schema = 'public') desc, (t.table_name in ('coin_log','app_coin_log')) desc, t.table_name
  limit 1;

  select format('%I.%I', t.table_schema, t.table_name)
  into v_withdrawals_tbl
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'user_id')
     and bool_or(c.column_name = 'amount')
     and bool_or(c.column_name = 'upi_id')
     and bool_or(c.column_name = 'status')
  order by (t.table_schema = 'public') desc, (t.table_name ilike '%withdraw%') desc, t.table_name
  limit 1;

  if v_users_tbl is null or v_sessions_tbl is null or v_withdrawals_tbl is null then
    raise exception 'Could not detect users, sessions, or withdrawals table.';
  end if;

  return query select v_users_tbl, coalesce(v_bal_col, 'balance'), v_sessions_tbl, v_coin_log_tbl, v_withdrawals_tbl;
end;
$$;

do $$
declare
  v_schema record;
begin
  select * into v_schema from public._p2w_wdr_detect_schema();
  execute format('alter table %s add column if not exists rejection_reason text', v_schema.withdrawals_table);
  raise notice 'Ensured rejection_reason column on %', v_schema.withdrawals_table;
end;
$$;

create or replace function public._p2w_wdr_auth(p_token text)
returns table(user_id text, user_role text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_schema record;
  v_sess_schema text;
  v_sess_name text;
  v_uid text;
  v_role text;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Session expired. Please log in again.';
  end if;

  select * into v_schema from public._p2w_wdr_detect_schema();
  v_sess_schema := replace(split_part(v_schema.sessions_table, '.', 1), '"', '');
  v_sess_name := replace(split_part(v_schema.sessions_table, '.', 2), '"', '');

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_sess_schema and table_name = v_sess_name and column_name = 'expires_at'
  ) then
    execute format('select user_id::text from %s where token = $1 and (expires_at is null or expires_at > now()) limit 1', v_schema.sessions_table)
      into v_uid using p_token;
  else
    execute format('select user_id::text from %s where token = $1 limit 1', v_schema.sessions_table)
      into v_uid using p_token;
  end if;

  if v_uid is null then
    raise exception 'Session expired. Please log in again.';
  end if;

  execute format(
    'select coalesce(nullif(to_jsonb(u)->>''role'',''''), case when coalesce((to_jsonb(u)->>''is_admin'')::boolean, false) then ''admin'' else ''user'' end) from %s u where u.id::text = $1 limit 1',
    v_schema.users_table
  ) into v_role using v_uid;

  if v_role is null then
    raise exception 'Account not found.';
  end if;

  return query select v_uid, v_role;
end;
$$;

-- Admin RPC: Reject withdrawal with a mandatory reason & refund reserved coins
create or replace function public.admin_reject_withdrawal(
  p_token text,
  p_request_id bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_schema record;
  v_reason text;
  v_req_uid text;
  v_req_amount numeric;
  v_req_status text;
  v_review_args text;
begin
  select * into v_auth from public._p2w_wdr_auth(p_token);
  if v_auth.user_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  v_reason := left(trim(coalesce(p_reason, '')), 300);
  if v_reason = '' then
    raise exception 'Rejection reason likhna zaroori hai.';
  end if;

  if p_request_id is null then
    raise exception 'Withdrawal request ID missing.';
  end if;

  select * into v_schema from public._p2w_wdr_detect_schema();

  execute format(
    'select user_id::text, amount, lower(coalesce(status, '''')) from %s where id::text = $1 limit 1',
    v_schema.withdrawals_table
  ) into v_req_uid, v_req_amount, v_req_status using p_request_id::text;

  if v_req_uid is null then
    raise exception 'Withdrawal request not found.';
  end if;

  if v_req_status <> 'pending' then
    raise exception 'Yeh withdrawal request pehle hi process ho chuki hai (%).', v_req_status;
  end if;

  select pg_get_function_identity_arguments(p.oid)
  into v_review_args
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_review_withdrawal'
  limit 1;

  if v_review_args is not null then
    if v_review_args ilike '%p_token%' and v_review_args ilike '%p_request_id%' and v_review_args ilike '%p_status%' then
      if v_review_args ilike '%integer%' and v_review_args not ilike '%bigint%' then
        execute 'select public.admin_review_withdrawal(p_token => $1, p_request_id => $2::integer, p_status => $3)'
          using p_token, p_request_id, 'rejected';
      else
        execute 'select public.admin_review_withdrawal(p_token => $1, p_request_id => $2::bigint, p_status => $3)'
          using p_token, p_request_id, 'rejected';
      end if;
    elsif v_review_args ilike '%integer%' and v_review_args not ilike '%bigint%' then
      execute 'select public.admin_review_withdrawal($1, $2::integer, $3)'
        using p_token, p_request_id, 'rejected';
    else
      execute 'select public.admin_review_withdrawal($1, $2::bigint, $3)'
        using p_token, p_request_id, 'rejected';
    end if;
  else
    execute format('update %s set status = ''rejected'' where id::text = $1 and lower(coalesce(status, '''')) = ''pending''', v_schema.withdrawals_table)
      using p_request_id::text;

    execute format('update %s set %I = coalesce(%I, 0) + $1 where id::text = $2', v_schema.users_table, v_schema.balance_col, v_schema.balance_col)
      using coalesce(v_req_amount, 0), v_req_uid;

    if v_schema.coin_log_table is not null then
      execute format('insert into %s (user_id, amount) values ($1, $2)', v_schema.coin_log_table)
        using v_req_uid, coalesce(v_req_amount, 0);
    end if;
  end if;

  execute format('update %s set rejection_reason = $1 where id::text = $2', v_schema.withdrawals_table)
    using v_reason, p_request_id::text;

  insert into public.withdrawal_rejection_reasons (request_id, user_id, reason, rejected_by, created_at)
  values (p_request_id, v_req_uid, v_reason, v_auth.user_id, now())
  on conflict (request_id) do update
    set reason = excluded.reason,
        rejected_by = excluded.rejected_by,
        created_at = now();

  return jsonb_build_object(
    'ok', true,
    'request_id', p_request_id,
    'status', 'rejected',
    'rejection_reason', v_reason
  );
end;
$$;

-- User RPC: list own withdrawal requests including rejection_reason
create or replace function public.my_withdrawal_requests_v2(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_schema record;
  v_rows jsonb;
begin
  select * into v_auth from public._p2w_wdr_auth(p_token);
  select * into v_schema from public._p2w_wdr_detect_schema();

  execute format($q$
    select coalesce(jsonb_agg(row_data), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'id', (to_jsonb(w)->>'id')::bigint,
        'user_id', w.user_id::text,
        'amount', w.amount,
        'upi_id', w.upi_id,
        'status', w.status,
        'rejection_reason', coalesce(
          nullif(trim(coalesce(to_jsonb(w)->>'rejection_reason', '')), ''),
          r.reason,
          ''
        ),
        'created_at', w.created_at
      ) as row_data
      from %s w
      left join public.withdrawal_rejection_reasons r
        on r.request_id = (to_jsonb(w)->>'id')::bigint
      where w.user_id::text = $1
      order by w.created_at desc, (to_jsonb(w)->>'id')::bigint desc
    ) t
  $q$, v_schema.withdrawals_table)
    into v_rows
    using v_auth.user_id;

  return coalesce(v_rows, '[]'::jsonb);
end;
$$;

-- Admin RPC: list all withdrawal requests including rejection_reason
create or replace function public.admin_list_withdrawal_requests_v2(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_schema record;
  v_has_email_tbl boolean := false;
  v_rows jsonb;
begin
  select * into v_auth from public._p2w_wdr_auth(p_token);
  if v_auth.user_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  select * into v_schema from public._p2w_wdr_detect_schema();

  select exists(
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'email_auth_accounts'
  ) into v_has_email_tbl;

  if v_has_email_tbl then
    execute format($q$
      select coalesce(jsonb_agg(row_data), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'id', (to_jsonb(w)->>'id')::bigint,
          'user_id', w.user_id::text,
          'email', coalesce(nullif(to_jsonb(u)->>'email', ''), nullif(ea.email, ''), ''),
          'display_name', coalesce(nullif(to_jsonb(u)->>'display_name', ''), nullif(ea.display_name, ''), ''),
          'amount', w.amount,
          'upi_id', w.upi_id,
          'status', w.status,
          'rejection_reason', coalesce(
            nullif(trim(coalesce(to_jsonb(w)->>'rejection_reason', '')), ''),
            r.reason,
            ''
          ),
          'created_at', w.created_at
        ) as row_data
        from %s w
        left join %s u on u.id::text = w.user_id::text
        left join public.email_auth_accounts ea on ea.user_id::text = w.user_id::text
        left join public.withdrawal_rejection_reasons r
          on r.request_id = (to_jsonb(w)->>'id')::bigint
        order by (lower(coalesce(w.status, '')) = 'pending') desc, w.created_at desc, (to_jsonb(w)->>'id')::bigint desc
      ) t
    $q$, v_schema.withdrawals_table, v_schema.users_table)
      into v_rows;
  else
    execute format($q$
      select coalesce(jsonb_agg(row_data), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'id', (to_jsonb(w)->>'id')::bigint,
          'user_id', w.user_id::text,
          'email', coalesce(nullif(to_jsonb(u)->>'email', ''), ''),
          'display_name', coalesce(nullif(to_jsonb(u)->>'display_name', ''), ''),
          'amount', w.amount,
          'upi_id', w.upi_id,
          'status', w.status,
          'rejection_reason', coalesce(
            nullif(trim(coalesce(to_jsonb(w)->>'rejection_reason', '')), ''),
            r.reason,
            ''
          ),
          'created_at', w.created_at
        ) as row_data
        from %s w
        left join %s u on u.id::text = w.user_id::text
        left join public.withdrawal_rejection_reasons r
          on r.request_id = (to_jsonb(w)->>'id')::bigint
        order by (lower(coalesce(w.status, '')) = 'pending') desc, w.created_at desc, (to_jsonb(w)->>'id')::bigint desc
      ) t
    $q$, v_schema.withdrawals_table, v_schema.users_table)
      into v_rows;
  end if;

  return coalesce(v_rows, '[]'::jsonb);
end;
$$;

grant execute on function public.admin_reject_withdrawal(text, bigint, text) to anon, authenticated;
grant execute on function public.my_withdrawal_requests_v2(text) to anon, authenticated;
grant execute on function public.admin_list_withdrawal_requests_v2(text) to anon, authenticated;

notify pgrst, 'reload schema';
