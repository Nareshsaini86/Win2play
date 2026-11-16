-- Play2Win Admin Game Controls + Minimum ₹300 Withdrawal (Supabase SQL Migration)
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Includes:
--   1. Server-side Minimum ₹300 (300 Coins) withdrawal enforcement trigger
--   2. Number Game single-round Admin result override (admin_set_number_result / admin_get_number_override)
--      + BEFORE INSERT/UPDATE trigger on the rounds/results table
--      + Safe auto-patch for Number Game settlement function so payouts & results both match

-- 1. Table for single-round Number Game admin overrides
create table if not exists public.number_game_admin_overrides (
  round_id text primary key,
  forced_num integer not null check (forced_num between 0 and 9),
  created_at timestamptz not null default now()
);

-- 2. Auth helper (standalone so this migration works even independently)
create or replace function public._p2w_ctrl_require_admin(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_users_tbl text;
  v_sessions_tbl text;
  v_sess_schema text;
  v_sess_name text;
  v_uid text;
  v_role text;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Session expired. Please log in again.';
  end if;

  select format('%I.%I', t.table_schema, t.table_name)
  into v_users_tbl
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('referral_settings','user_referrals','referral_events','email_auth_accounts','aviator_rounds','aviator_global_rounds','aviator_bets','number_game_admin_overrides')
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

  if v_users_tbl is null or v_sessions_tbl is null then
    raise exception 'Could not detect users or sessions table.';
  end if;

  v_sess_schema := replace(split_part(v_sessions_tbl, '.', 1), '"', '');
  v_sess_name := replace(split_part(v_sessions_tbl, '.', 2), '"', '');

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_sess_schema and table_name = v_sess_name and column_name = 'expires_at'
  ) then
    execute format('select user_id::text from %s where token = $1 and (expires_at is null or expires_at > now()) limit 1', v_sessions_tbl)
      into v_uid using p_token;
  else
    execute format('select user_id::text from %s where token = $1 limit 1', v_sessions_tbl)
      into v_uid using p_token;
  end if;

  if v_uid is null then
    raise exception 'Session expired. Please log in again.';
  end if;

  execute format(
    'select coalesce(nullif(to_jsonb(u)->>''role'',''''), case when coalesce((to_jsonb(u)->>''is_admin'')::boolean, false) then ''admin'' else ''user'' end) from %s u where u.id::text = $1 limit 1',
    v_users_tbl
  ) into v_role using v_uid;

  if v_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  return v_uid;
end;
$$;

-- 3. Admin RPC: set or clear winning number (0..9) for one specific round
create or replace function public.admin_set_number_result(
  p_token text,
  p_round_id text,
  p_num integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round text;
begin
  perform public._p2w_ctrl_require_admin(p_token);

  v_round := trim(coalesce(p_round_id, ''));
  if v_round = '' then
    raise exception 'Active round ID missing.';
  end if;

  if p_num is null then
    delete from public.number_game_admin_overrides where round_id = v_round;
    return jsonb_build_object('round_id', v_round, 'forced_num', null);
  end if;

  if p_num < 0 or p_num > 9 then
    raise exception 'Number 0 se 9 ke beech hona chahiye.';
  end if;

  insert into public.number_game_admin_overrides (round_id, forced_num, created_at)
  values (v_round, p_num, now())
  on conflict (round_id) do update
    set forced_num = excluded.forced_num,
        created_at = now();

  return jsonb_build_object('round_id', v_round, 'forced_num', p_num);
end;
$$;

create or replace function public.admin_get_number_override(
  p_token text,
  p_round_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round text;
  v_num integer;
begin
  perform public._p2w_ctrl_require_admin(p_token);
  v_round := trim(coalesce(p_round_id, ''));

  select forced_num into v_num
  from public.number_game_admin_overrides
  where round_id = v_round
  limit 1;

  return jsonb_build_object('round_id', v_round, 'forced_num', v_num);
end;
$$;

-- 4. Trigger functions for Number Game results and Minimum ₹300 withdrawal
create or replace function public._p2w_trg_apply_number_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_forced integer;
begin
  select forced_num into v_forced
  from public.number_game_admin_overrides
  where round_id = trim(new.round::text)
  limit 1;

  if v_forced is not null then
    new.num := v_forced;
  end if;
  return new;
end;
$$;

create or replace function public._p2w_trg_min_withdrawal_300()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.amount, 0) < 300 then
    raise exception 'Minimum withdrawal ₹300 (300 coins) hai.';
  end if;
  return new;
end;
$$;

-- 5. Auto-attach triggers & safely patch Number Game random number assignment
do $$
declare
  v_withdraw_tbl text;
  v_results_tbl text;
  v_res_name text;
  v_fn record;
  v_def text;
  v_num_match text[];
  v_round_match text[];
  v_num_var text;
  v_round_var text;
  v_inject text;
  v_new_def text;
begin
  -- A) Attach Minimum ₹300 withdrawal trigger to withdrawal requests table
  select format('%I.%I', t.table_schema, t.table_name)
  into v_withdraw_tbl
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

  if v_withdraw_tbl is not null then
    execute format('drop trigger if exists trg_p2w_min_withdrawal_300 on %s', v_withdraw_tbl);
    execute format(
      'create trigger trg_p2w_min_withdrawal_300 before insert on %s for each row execute function public._p2w_trg_min_withdrawal_300()',
      v_withdraw_tbl
    );
    raise notice 'Attached minimum ₹300 withdrawal trigger on %', v_withdraw_tbl;
  end if;

  -- B) Attach Number Game override trigger on results/rounds table (has round + num columns)
  select format('%I.%I', t.table_schema, t.table_name), t.table_name
  into v_results_tbl, v_res_name
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'round')
     and bool_or(c.column_name = 'num')
  order by (t.table_schema = 'public') desc, (t.table_name in ('rounds','results','game_rounds')) desc, t.table_name
  limit 1;

  if v_results_tbl is not null then
    execute format('drop trigger if exists trg_p2w_number_override on %s', v_results_tbl);
    execute format(
      'create trigger trg_p2w_number_override before insert or update on %s for each row execute function public._p2w_trg_apply_number_override()',
      v_results_tbl
    );
    raise notice 'Attached Number Game override trigger on %', v_results_tbl;

    -- C) Safely patch get_state / settle helper in public schema so bet payouts also use forced_num
    for v_fn in
      select p.oid, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname not like '\_p2w\_%' escape '\'
        and p.proname not in ('admin_set_number_result', 'admin_get_number_override')
        and p.prosrc ilike '%' || v_res_name || '%'
        and p.prosrc ilike '%random()%'
    loop
      begin
        v_def := pg_get_functiondef(v_fn.oid);
        if position('number_game_admin_overrides' in v_def) = 0 then
          v_num_match := regexp_match(
            v_def,
            '([a-zA-Z_][a-zA-Z0-9_]*)\s*:=\s*[^;]*random\s*\(\s*\)[^;]*;'
          );
          v_round_match := regexp_match(
            v_def,
            'insert\s+into\s+(?:public\.)?' || v_res_name || '\s*\([^)]*\bround\b[^)]*\bnum\b[^)]*\)\s*values\s*\(\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*,',
            'i'
          );
          if v_round_match is null then
            v_round_match := regexp_match(
              v_def,
              'where\s+round\s*=\s*([a-zA-Z_][a-zA-Z0-9_]*)',
              'i'
            );
          end if;

          if v_num_match is not null and v_round_match is not null then
            v_num_var := v_num_match[1];
            v_round_var := v_round_match[1];
            v_inject := v_num_match[0] || E'\n  ' ||
              v_num_var || ' := coalesce((select forced_num from public.number_game_admin_overrides where round_id = trim((' ||
              v_round_var || ')::text) limit 1), ' || v_num_var || ');';
            v_new_def := replace(v_def, v_num_match[0], v_inject);
            if v_new_def <> v_def then
              execute v_new_def;
              raise notice 'Patched Number Game function % (%) to respect admin override.', v_fn.proname, v_num_var;
            end if;
          end if;
        end if;
      exception when others then
        raise notice 'Skipped auto-patch for %: %', v_fn.proname, sqlerrm;
      end;
    end loop;
  end if;
end;
$$;

grant execute on function public.admin_set_number_result(text, text, integer) to anon, authenticated;
grant execute on function public.admin_get_number_override(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
