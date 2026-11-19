-- Play2Win Admin Full User Deletion Across Every Database Table (Supabase SQL Migration)
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Upgrades both `admin_delete_user_full(p_token, p_id)` and `admin_delete_user(p_token, p_id)`
-- so clicking Delete in Admin -> Users permanently removes the user AND all their data from
-- every table (sessions, coin logs, bets, gold ball, aviator, ludo, rummy, fruit cut,
-- deposits, withdrawals, withdrawal rejection reasons, saved UPIs, referrals, email auth, OTPs, etc.).

create or replace function public._p2w_del_require_admin(p_token text)
returns table(admin_id text, users_table text, sessions_table text)
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
    and t.table_name not in (
      'referral_settings','user_referrals','referral_events',
      'email_auth_accounts','email_smtp_settings','email_signup_otps',
      'aviator_rounds','aviator_global_rounds','aviator_bets',
      'number_game_admin_overrides','withdrawal_rejection_reasons',
      'ludo_matches','ludo_match_players','ludo_platform_fees',
      'rummy_matches','rummy_match_players','rummy_platform_fees',
      'fruitcut_matches','fruitcut_match_players','fruitcut_platform_fees'
    )
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

  return query select v_uid, v_users_tbl, v_sessions_tbl;
end;
$$;

create or replace function public.admin_delete_user_full(
  p_token text,
  p_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_uid text;
  v_users_schema text;
  v_users_name text;
  v_target_role text;
  v_email text := '';
  v_auth_email text := '';
  v_deleted jsonb := '{}'::jsonb;
  v_cnt bigint := 0;
  v_user_rows bigint := 0;
  v_game text;
  v_pass integer;
  v_tbl record;
  v_users_reg oid;
  v_fk_cols text[];
  v_where_parts text[];
  v_col text;
  v_had_fk_retry boolean;
  v_done_tables text[] := array[]::text[];
begin
  select * into v_auth from public._p2w_del_require_admin(p_token);

  v_uid := trim(coalesce(p_id, ''));
  if v_uid = '' then
    raise exception 'User ID missing.';
  end if;

  if v_uid = v_auth.admin_id then
    raise exception 'You cannot delete the active admin account.';
  end if;

  -- Serialize bulk deletes to avoid lock contention across shared referral/match tables
  perform pg_advisory_xact_lock(92847901);

  v_users_schema := replace(split_part(v_auth.users_table, '.', 1), '"', '');
  v_users_name := replace(split_part(v_auth.users_table, '.', 2), '"', '');
  v_users_reg := to_regclass(v_auth.users_table);

  execute format(
    'select
       coalesce(nullif(to_jsonb(u)->>''role'',''''), case when coalesce((to_jsonb(u)->>''is_admin'')::boolean, false) then ''admin'' else ''user'' end),
       lower(trim(coalesce(to_jsonb(u)->>''email'', '''')))
     from %s u where u.id::text = $1 limit 1',
    v_auth.users_table
  ) into v_target_role, v_email using v_uid;

  if v_target_role = 'admin' then
    raise exception 'Admin accounts cannot be deleted.';
  end if;

  v_email := coalesce(v_email, '');
  if v_email = '' and to_regclass('public.email_auth_accounts') is not null then
    execute 'select lower(trim(coalesce(email, ''''))) from public.email_auth_accounts where user_id::text = $1 limit 1'
      into v_auth_email using v_uid;
    v_email := coalesce(v_auth_email, '');
  end if;

  -- 1. Clean Ludo / Rummy / Fruit Cut player rows & solo/bot matches (+ cascaded fee rows)
  foreach v_game in array array['ludo', 'rummy', 'fruitcut'] loop
    if to_regclass('public.' || v_game || '_match_players') is not null then
      execute format('delete from public.%I where user_id::text = $1', v_game || '_match_players')
        using v_uid;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        v_deleted := v_deleted || jsonb_build_object(v_game || '_match_players', v_cnt);
      end if;
    end if;

    if to_regclass('public.' || v_game || '_matches') is not null then
      if to_regclass('public.' || v_game || '_match_players') is not null then
        execute format(
          'delete from public.%I m
           where (
             m.winner_user_id::text = $1
             or exists (
               select 1 from jsonb_array_elements(coalesce(m.players_json, ''[]''::jsonb)) el
               where el->>''user_id'' = $1
             )
           )
           and not exists (
             select 1 from public.%I p where p.match_id = m.id
           )',
          v_game || '_matches',
          v_game || '_match_players'
        ) using v_uid;
        get diagnostics v_cnt = row_count;
        if v_cnt > 0 then
          v_deleted := v_deleted || jsonb_build_object(v_game || '_matches', v_cnt);
        end if;
      end if;

      execute format(
        'update public.%I m
         set winner_user_id = case when m.winner_user_id::text = $1 then null else m.winner_user_id end,
             winner_name = case when m.winner_user_id::text = $1 then ''Deleted User'' else m.winner_name end,
             players_json = coalesce((
               select jsonb_agg(el)
               from jsonb_array_elements(coalesce(m.players_json, ''[]''::jsonb)) el
               where coalesce(el->>''user_id'', '''') <> $1
             ), ''[]''::jsonb)
         where m.winner_user_id::text = $1
            or exists (
              select 1 from jsonb_array_elements(coalesce(m.players_json, ''[]''::jsonb)) el
              where el->>''user_id'' = $1
            )',
        v_game || '_matches'
      ) using v_uid;
    end if;
  end loop;

  -- 2. Clean Referral tables & clear referred_by pointer for any users they referred
  if to_regclass('public.referral_events') is not null then
    delete from public.referral_events
    where referrer_id::text = v_uid or referred_id::text = v_uid;
    get diagnostics v_cnt = row_count;
    if v_cnt > 0 then
      v_deleted := v_deleted || jsonb_build_object('referral_events', v_cnt);
    end if;
  end if;

  if to_regclass('public.user_referrals') is not null then
    update public.user_referrals set referred_by = null where referred_by::text = v_uid;
    delete from public.user_referrals where user_id::text = v_uid;
    get diagnostics v_cnt = row_count;
    if v_cnt > 0 then
      v_deleted := v_deleted || jsonb_build_object('user_referrals', v_cnt);
    end if;
  end if;

  -- 3. Clean Withdrawal rejection reasons
  if to_regclass('public.withdrawal_rejection_reasons') is not null then
    update public.withdrawal_rejection_reasons set rejected_by = null where rejected_by::text = v_uid;
    delete from public.withdrawal_rejection_reasons where user_id::text = v_uid;
    get diagnostics v_cnt = row_count;
    if v_cnt > 0 then
      v_deleted := v_deleted || jsonb_build_object('withdrawal_rejection_reasons', v_cnt);
    end if;
  end if;

  -- 4. Clean Email auth account & signup OTPs
  if to_regclass('public.email_auth_accounts') is not null then
    delete from public.email_auth_accounts
    where user_id::text = v_uid
       or (v_email <> '' and lower(email) = v_email);
    get diagnostics v_cnt = row_count;
    if v_cnt > 0 then
      v_deleted := v_deleted || jsonb_build_object('email_auth_accounts', v_cnt);
    end if;
  end if;

  if to_regclass('public.email_signup_otps') is not null and v_email <> '' then
    delete from public.email_signup_otps where lower(email) = v_email;
    get diagnostics v_cnt = row_count;
    if v_cnt > 0 then
      v_deleted := v_deleted || jsonb_build_object('email_signup_otps', v_cnt);
    end if;
  end if;

  -- 5. Clean Aviator bets
  if to_regclass('public.aviator_bets') is not null then
    delete from public.aviator_bets where user_id::text = v_uid;
    get diagnostics v_cnt = row_count;
    if v_cnt > 0 then
      v_deleted := v_deleted || jsonb_build_object('aviator_bets', v_cnt);
    end if;
  end if;

  -- 6. Dynamic sweep across EVERY other table in non-system schemas
  --    Catches sessions, coin_log, number bets, gold ball bets/rounds, deposits,
  --    withdrawal requests, withdrawal UPIs, daily rewards, and any FK child tables.
  for v_pass in 1..5 loop
    v_had_fk_retry := false;

    for v_tbl in
      select
        t.table_schema,
        t.table_name,
        format('%I.%I', t.table_schema, t.table_name) as fq_name
      from information_schema.tables t
      where t.table_type = 'BASE TABLE'
        and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
        and not (t.table_schema = v_users_schema and t.table_name = v_users_name)
        and t.table_name not in (
          'referral_settings', 'email_smtp_settings', 'number_game_admin_overrides',
          'aviator_global_rounds', 'ludo_matches', 'rummy_matches', 'fruitcut_matches',
          'ludo_platform_fees', 'rummy_platform_fees', 'fruitcut_platform_fees',
          'user_referrals', 'referral_events', 'withdrawal_rejection_reasons',
          'email_auth_accounts', 'email_signup_otps', 'aviator_bets',
          'ludo_match_players', 'rummy_match_players', 'fruitcut_match_players',
          'payment_upis', 'upi_accounts', 'app_settings'
        )
        and not (t.table_name ilike '%payment_upi%')
        and not (format('%I.%I', t.table_schema, t.table_name) = any(v_done_tables))
      order by (t.table_schema = 'public') desc, t.table_name
    loop
      v_where_parts := array[]::text[];

      -- Any column matching common user reference names
      for v_col in
        select c.column_name
        from information_schema.columns c
        where c.table_schema = v_tbl.table_schema
          and c.table_name = v_tbl.table_name
          and c.column_name in (
            'user_id', 'uid', 'player_id', 'account_id', 'member_id',
            'referrer_id', 'referred_id', 'winner_user_id', 'created_by'
          )
      loop
        v_where_parts := array_append(v_where_parts, format('%I::text = %L', v_col, v_uid));
      end loop;

      -- Plus any column that has a direct Foreign Key referencing users_table
      if v_users_reg is not null then
        select array_agg(distinct a.attname::text)
        into v_fk_cols
        from pg_constraint con
        join pg_class cl on cl.oid = con.conrelid
        join pg_namespace ns on ns.oid = cl.relnamespace
        join unnest(con.conkey) as k(attnum) on true
        join pg_attribute a on a.attrelid = cl.oid and a.attnum = k.attnum
        where con.contype = 'f'
          and con.confrelid = v_users_reg
          and ns.nspname = v_tbl.table_schema
          and cl.relname = v_tbl.table_name;

        if v_fk_cols is not null then
          foreach v_col in array v_fk_cols loop
            if not (format('%I::text = %L', v_col, v_uid) = any(v_where_parts)) then
              v_where_parts := array_append(v_where_parts, format('%I::text = %L', v_col, v_uid));
            end if;
          end loop;
        end if;
      end if;

      -- Match by email column too when available
      if v_email <> '' then
        for v_col in
          select c.column_name
          from information_schema.columns c
          where c.table_schema = v_tbl.table_schema
            and c.table_name = v_tbl.table_name
            and c.column_name in ('email', 'user_email')
        loop
          v_where_parts := array_append(v_where_parts, format('lower(%I::text) = %L', v_col, v_email));
        end loop;
      end if;

      if array_length(v_where_parts, 1) is null then
        v_done_tables := array_append(v_done_tables, v_tbl.fq_name);
        continue;
      end if;

      begin
        execute format('delete from %s where %s', v_tbl.fq_name, array_to_string(v_where_parts, ' or '));
        get diagnostics v_cnt = row_count;
        if v_cnt > 0 then
          v_deleted := v_deleted || jsonb_build_object(v_tbl.table_name, v_cnt);
        end if;
        v_done_tables := array_append(v_done_tables, v_tbl.fq_name);
      exception
        when foreign_key_violation then
          v_had_fk_retry := true;
      end;
    end loop;

    exit when not v_had_fk_retry;
  end loop;

  -- 7. Best-effort cleanup in Supabase auth.users (for OAuth users, ignored safely if not applicable)
  begin
    if v_uid ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      execute 'delete from auth.users where id = $1::uuid' using v_uid;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        v_deleted := v_deleted || jsonb_build_object('auth.users', v_cnt);
      end if;
    elsif v_email <> '' then
      execute 'delete from auth.users where lower(email) = $1' using v_email;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        v_deleted := v_deleted || jsonb_build_object('auth.users', v_cnt);
      end if;
    end if;
  exception when others then
    null;
  end;

  -- 8. Finally delete the user record itself from the main users table
  execute format('delete from %s where id::text = $1', v_auth.users_table) using v_uid;
  get diagnostics v_user_rows = row_count;
  if v_user_rows > 0 then
    v_deleted := v_deleted || jsonb_build_object(v_users_name, v_user_rows);
  end if;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_uid,
    'email', nullif(v_email, ''),
    'deleted_user_rows', v_user_rows,
    'deleted_tables', v_deleted
  );
end;
$$;

-- Upgrade legacy admin_delete_user signatures so any caller/version also deletes across every table
do $$
declare
  v_sig record;
begin
  for v_sig in
    select pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_delete_user'
  loop
    execute format('drop function if exists public.admin_delete_user(%s)', v_sig.args);
  end loop;
end;
$$;

create or replace function public.admin_delete_user(
  p_token text,
  p_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.admin_delete_user_full(p_token, p_id);
end;
$$;

grant execute on function public.admin_delete_user_full(text, text) to anon, authenticated;
grant execute on function public.admin_delete_user(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
