-- Play2Win Refer & Earn + App Download + Admin Analytics (Supabase SQL Migration)
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Automatically detects your existing users, sessions, and coin_log table names.

-- 1. Referral configuration (App/APK download link, reward amount, detected schema tables)
create table if not exists public.referral_settings (
  id integer primary key default 1 check (id = 1),
  download_url text not null default '',
  reward_coins integer not null default 20 check (reward_coins > 0),
  users_table text,
  balance_col text not null default 'balance',
  sessions_table text,
  coin_log_table text,
  updated_at timestamptz not null default now()
);

alter table public.referral_settings add column if not exists users_table text;
alter table public.referral_settings add column if not exists balance_col text not null default 'balance';
alter table public.referral_settings add column if not exists sessions_table text;
alter table public.referral_settings add column if not exists coin_log_table text;

insert into public.referral_settings (id, download_url, reward_coins)
values (1, '', 20)
on conflict (id) do nothing;

-- Auto-detect existing users, sessions, and coin_log tables in this Supabase project
do $$
declare
  v_users_tbl text;
  v_bal_col text;
  v_sessions_tbl text;
  v_coin_log_tbl text;
  v_all_tables text;
begin
  -- Find users/accounts table (has id, role, and balance/coins/credits)
  select format('%I.%I', t.table_schema, t.table_name),
         max(case when c.column_name in ('balance','coins','credits') then c.column_name end)
  into v_users_tbl, v_bal_col
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('referral_settings','user_referrals','referral_events')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'id')
     and bool_or(c.column_name = 'role')
     and bool_or(c.column_name in ('balance','coins','credits'))
  order by (t.table_schema = 'public') desc, t.table_name
  limit 1;

  -- Fallback if users table uses is_admin instead of role
  if v_users_tbl is null then
    select format('%I.%I', t.table_schema, t.table_name),
           max(case when c.column_name in ('balance','coins','credits') then c.column_name end)
    into v_users_tbl, v_bal_col
    from information_schema.tables t
    join information_schema.columns c
      on c.table_schema = t.table_schema and c.table_name = t.table_name
    where t.table_type = 'BASE TABLE'
      and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
      and t.table_name not in ('referral_settings','user_referrals','referral_events')
    group by t.table_schema, t.table_name
    having bool_or(c.column_name = 'id')
       and bool_or(c.column_name in ('balance','coins','credits'))
    order by (t.table_schema = 'public') desc, t.table_name
    limit 1;
  end if;

  if v_users_tbl is null then
    select string_agg(table_schema || '.' || table_name, ', ')
    into v_all_tables
    from information_schema.tables
    where table_type = 'BASE TABLE'
      and table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions');
    raise exception 'Could not auto-detect users table. Found tables: %', coalesce(v_all_tables, 'none');
  end if;

  -- Find sessions table (has token and user_id)
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
  order by (t.table_schema = 'public') desc, (t.table_name = 'sessions') desc, t.table_name
  limit 1;

  -- Find coin log table (has user_id, amount, created_at; excludes bet/deposit/withdrawal tables)
  select format('%I.%I', t.table_schema, t.table_name)
  into v_coin_log_tbl
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('referral_settings','user_referrals','referral_events')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'user_id')
     and bool_or(c.column_name = 'amount')
     and bool_or(c.column_name = 'created_at')
     and not bool_or(c.column_name in ('target','utr','upi_id','round','payout'))
  order by (t.table_schema = 'public') desc, (t.table_name = 'coin_log') desc, t.table_name
  limit 1;

  update public.referral_settings
  set users_table = v_users_tbl,
      balance_col = coalesce(v_bal_col, 'balance'),
      sessions_table = v_sessions_tbl,
      coin_log_table = v_coin_log_tbl,
      updated_at = now()
  where id = 1;

  raise notice 'Play2Win Referral detected -> users: %, balance_col: %, sessions: %, coin_log: %',
    v_users_tbl, v_bal_col, v_sessions_tbl, v_coin_log_tbl;
end;
$$;

-- 2. Per-user referral codes, share counters, and earnings summary
create table if not exists public.user_referrals (
  user_id text primary key,
  referral_code text not null unique,
  referred_by text,
  referred_code_used text,
  referral_rewarded boolean not null default false,
  total_shares integer not null default 0,
  total_referrals integer not null default 0,
  total_earned integer not null default 0,
  created_at timestamptz not null default now()
);

-- 3. Immutable audit log of completed referrals (one claim per new user)
create table if not exists public.referral_events (
  id bigserial primary key,
  referrer_id text not null,
  referred_id text not null unique,
  referral_code text not null,
  referrer_coins integer not null default 20,
  referred_coins integer not null default 20,
  created_at timestamptz not null default now()
);

create index if not exists idx_referral_events_referrer on public.referral_events (referrer_id, created_at desc);

-- Helper: validate session token and return user_id & role using detected tables
create or replace function public._p2w_auth_user(p_token text)
returns table(user_id text, user_role text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg public.referral_settings;
  v_uid text;
  v_role text;
  v_sess_schema text;
  v_sess_name text;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Session expired. Please log in again.';
  end if;

  select * into v_cfg from public.referral_settings where id = 1;
  if v_cfg.sessions_table is null or v_cfg.users_table is null then
    raise exception 'Referral settings not initialized. Re-run supabase_refer_earn.sql.';
  end if;

  v_sess_schema := replace(split_part(v_cfg.sessions_table, '.', 1), '"', '');
  v_sess_name := replace(split_part(v_cfg.sessions_table, '.', 2), '"', '');

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_sess_schema and table_name = v_sess_name and column_name = 'expires_at'
  ) then
    execute format('select user_id::text from %s where token = $1 and (expires_at is null or expires_at > now()) limit 1', v_cfg.sessions_table)
      into v_uid using p_token;
  else
    execute format('select user_id::text from %s where token = $1 limit 1', v_cfg.sessions_table)
      into v_uid using p_token;
  end if;

  if v_uid is null then
    raise exception 'Session expired. Please log in again.';
  end if;

  execute format(
    'select coalesce(nullif(to_jsonb(u)->>''role'',''''), case when coalesce((to_jsonb(u)->>''is_admin'')::boolean, false) then ''admin'' else ''user'' end) from %s u where u.id::text = $1 limit 1',
    v_cfg.users_table
  ) into v_role using v_uid;

  if v_role is null then
    raise exception 'Account not found.';
  end if;

  return query select v_uid, v_role;
end;
$$;

-- Helper: ensure user has a deterministic unique referral code
create or replace function public._p2w_ensure_referral_profile(p_user_id text)
returns public.user_referrals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.user_referrals;
  v_code text;
begin
  select * into v_row from public.user_referrals where user_id = p_user_id;
  if found then
    return v_row;
  end if;

  v_code := 'P2W' || upper(substr(md5(p_user_id || ':' || extract(epoch from now())::text || random()::text), 1, 7));
  insert into public.user_referrals (user_id, referral_code)
  values (p_user_id, v_code)
  on conflict (user_id) do nothing;

  select * into v_row from public.user_referrals where user_id = p_user_id;
  return v_row;
end;
$$;

-- 4. Public download info (for landing / referral links before login)
create or replace function public.get_public_download_info()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg public.referral_settings;
begin
  select * into v_cfg from public.referral_settings where id = 1;
  return jsonb_build_object(
    'download_url', coalesce(v_cfg.download_url, ''),
    'reward_coins', coalesce(v_cfg.reward_coins, 20)
  );
end;
$$;

-- 5. Player: get own referral code, share link, stats, and recent referral rewards
create or replace function public.get_referral_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_profile public.user_referrals;
  v_cfg public.referral_settings;
  v_base_url text;
  v_sep text;
  v_history jsonb;
begin
  select * into v_auth from public._p2w_auth_user(p_token);
  v_profile := public._p2w_ensure_referral_profile(v_auth.user_id);
  select * into v_cfg from public.referral_settings where id = 1;

  v_base_url := trim(coalesce(v_cfg.download_url, ''));
  v_sep := case when position('?' in v_base_url) > 0 then '&' else '?' end;

  execute format($q$
    select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    from (
      select
        e.id,
        coalesce(nullif(to_jsonb(u)->>'display_name', ''), nullif(to_jsonb(u)->>'email', ''), e.referred_id) as friend_label,
        e.referrer_coins as coins,
        e.created_at
      from public.referral_events e
      left join %s u on u.id::text = e.referred_id
      where e.referrer_id = $1
      order by e.created_at desc
      limit 20
    ) t
  $q$, v_cfg.users_table) into v_history using v_auth.user_id;

  return jsonb_build_object(
    'referral_code', v_profile.referral_code,
    'download_url', v_base_url,
    'share_link', case when v_base_url = '' then '' else v_base_url end,
    'reward_coins', coalesce(v_cfg.reward_coins, 20),
    'total_shares', v_profile.total_shares,
    'total_referrals', v_profile.total_referrals,
    'total_earned', v_profile.total_earned,
    'referred_by', v_profile.referred_by,
    'referred_code_used', v_profile.referred_code_used,
    'referral_rewarded', v_profile.referral_rewarded,
    'history', coalesce(v_history, '[]'::jsonb)
  );
end;
$$;

-- 6. Player: track share click (increments total_shares in Supabase)
create or replace function public.record_referral_share(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_profile public.user_referrals;
  v_cfg public.referral_settings;
  v_base_url text;
  v_sep text;
begin
  select * into v_auth from public._p2w_auth_user(p_token);
  perform public._p2w_ensure_referral_profile(v_auth.user_id);

  update public.user_referrals
  set total_shares = total_shares + 1
  where user_id = v_auth.user_id
  returning * into v_profile;

  select * into v_cfg from public.referral_settings where id = 1;
  v_base_url := trim(coalesce(v_cfg.download_url, ''));
  v_sep := case when position('?' in v_base_url) > 0 then '&' else '?' end;

  return jsonb_build_object(
    'total_shares', v_profile.total_shares,
    'referral_code', v_profile.referral_code,
    'download_url', v_base_url,
    'share_link', case when v_base_url = '' then '' else v_base_url end
  );
end;
$$;

-- 7. Player: redeem a referral code (credits 20 coins to BOTH referrer and new user)
create or replace function public.claim_referral_code(p_token text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_my_profile public.user_referrals;
  v_referrer public.user_referrals;
  v_cfg public.referral_settings;
  v_clean_code text;
  v_reward integer;
begin
  select * into v_auth from public._p2w_auth_user(p_token);
  if v_auth.user_role = 'admin' then
    raise exception 'Admin accounts cannot claim referral rewards.';
  end if;

  v_clean_code := upper(trim(coalesce(p_code, '')));
  if length(v_clean_code) < 4 then
    raise exception 'Valid referral code enter karein.';
  end if;

  v_my_profile := public._p2w_ensure_referral_profile(v_auth.user_id);
  if v_my_profile.referral_rewarded or exists (select 1 from public.referral_events where referred_id = v_auth.user_id) then
    raise exception 'Aap pehle hi referral bonus claim kar chuke hain.';
  end if;

  select * into v_referrer
  from public.user_referrals
  where upper(referral_code) = v_clean_code
  limit 1;

  if not found then
    raise exception 'Referral code invalid hai ya exist nahi karta.';
  end if;

  if v_referrer.user_id = v_auth.user_id then
    raise exception 'Aap apna khud ka referral code use nahi kar sakte.';
  end if;

  select * into v_cfg from public.referral_settings where id = 1;
  v_reward := coalesce(v_cfg.reward_coins, 20);

  insert into public.referral_events (referrer_id, referred_id, referral_code, referrer_coins, referred_coins)
  values (v_referrer.user_id, v_auth.user_id, v_referrer.referral_code, v_reward, v_reward);

  update public.user_referrals
  set referred_by = v_referrer.user_id,
      referred_code_used = v_referrer.referral_code,
      referral_rewarded = true
  where user_id = v_auth.user_id;

  update public.user_referrals
  set total_referrals = total_referrals + 1,
      total_earned = total_earned + v_reward
  where user_id = v_referrer.user_id;

  -- Credit +20 coins to BOTH wallets atomically
  execute format('update %s set %I = coalesce(%I, 0) + $1 where id::text = $2', v_cfg.users_table, v_cfg.balance_col, v_cfg.balance_col)
    using v_reward, v_referrer.user_id;
  execute format('update %s set %I = coalesce(%I, 0) + $1 where id::text = $2', v_cfg.users_table, v_cfg.balance_col, v_cfg.balance_col)
    using v_reward, v_auth.user_id;

  -- Record in coin_log if detected
  if v_cfg.coin_log_table is not null then
    begin
      execute format('insert into %s (user_id, amount, created_at) values ($1, $2, now()), ($3, $2, now())', v_cfg.coin_log_table)
        using v_referrer.user_id, v_reward, v_auth.user_id;
    exception when others then
      null;
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'reward', v_reward,
    'referrer_id', v_referrer.user_id,
    'referral_code', v_referrer.referral_code
  );
end;
$$;

-- 8. Admin: view all users' share counts, referral installs, coins earned & recent referral events
create or replace function public.admin_referral_overview(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_cfg public.referral_settings;
  v_users jsonb;
  v_recent jsonb;
  v_total_shares bigint;
  v_total_refs bigint;
  v_total_coins bigint;
begin
  select * into v_auth from public._p2w_auth_user(p_token);
  if v_auth.user_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  select * into v_cfg from public.referral_settings where id = 1;

  select
    coalesce(sum(total_shares), 0),
    coalesce(sum(total_referrals), 0),
    coalesce(sum(total_earned), 0)
  into v_total_shares, v_total_refs, v_total_coins
  from public.user_referrals;

  execute format($q$
    select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    from (
      select
        r.user_id,
        coalesce(nullif(to_jsonb(u)->>'email', ''), nullif(to_jsonb(u)->>'display_name', ''), r.user_id) as user_label,
        r.referral_code,
        r.total_shares,
        r.total_referrals,
        r.total_earned
      from public.user_referrals r
      left join %s u on u.id::text = r.user_id
      where coalesce(to_jsonb(u)->>'role', 'user') <> 'admin'
      order by r.total_referrals desc, r.total_shares desc, r.total_earned desc, r.created_at desc
    ) t
  $q$, v_cfg.users_table) into v_users;

  execute format($q$
    select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    from (
      select
        e.id,
        e.created_at,
        coalesce(nullif(to_jsonb(ur)->>'email', ''), nullif(to_jsonb(ur)->>'display_name', ''), e.referrer_id) as referrer_label,
        coalesce(nullif(to_jsonb(ud)->>'email', ''), nullif(to_jsonb(ud)->>'display_name', ''), e.referred_id) as referred_label,
        e.referral_code,
        e.referrer_coins,
        e.referred_coins
      from public.referral_events e
      left join %s ur on ur.id::text = e.referrer_id
      left join %s ud on ud.id::text = e.referred_id
      order by e.created_at desc
      limit 50
    ) t
  $q$, v_cfg.users_table, v_cfg.users_table) into v_recent;

  return jsonb_build_object(
    'download_url', coalesce(v_cfg.download_url, ''),
    'reward_coins', coalesce(v_cfg.reward_coins, 20),
    'total_shares', v_total_shares,
    'total_referrals', v_total_refs,
    'total_coins_distributed', v_total_coins * 2,
    'users', coalesce(v_users, '[]'::jsonb),
    'recent', coalesce(v_recent, '[]'::jsonb)
  );
end;
$$;

-- 9. Admin: configure the APK / app download URL shared by players
create or replace function public.admin_set_download_url(p_token text, p_download_url text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_url text;
begin
  select * into v_auth from public._p2w_auth_user(p_token);
  if v_auth.user_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  v_url := trim(coalesce(p_download_url, ''));
  if v_url !~ '^https?://' then
    raise exception 'Valid https:// or http:// download URL enter karein.';
  end if;

  insert into public.referral_settings (id, download_url, reward_coins, updated_at)
  values (1, v_url, 20, now())
  on conflict (id) do update
    set download_url = excluded.download_url,
        updated_at = now();

  return jsonb_build_object('download_url', v_url);
end;
$$;

grant execute on function public.get_public_download_info() to anon, authenticated;
grant execute on function public.get_referral_info(text) to anon, authenticated;
grant execute on function public.record_referral_share(text) to anon, authenticated;
grant execute on function public.claim_referral_code(text, text) to anon, authenticated;
grant execute on function public.admin_referral_overview(text) to anon, authenticated;
grant execute on function public.admin_set_download_url(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
