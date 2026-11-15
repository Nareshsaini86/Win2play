-- Play2Win Self-Service Email + Password Sign Up & Login (Supabase SQL Migration)
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Allows new users to register with their own Email ID and Password (with 20 starting coins)
-- and log in directly inside the app without needing external Google OAuth.

create extension if not exists pgcrypto;

create table if not exists public.email_auth_accounts (
  email text primary key,
  user_id text not null unique,
  display_name text not null default '',
  password_hash text not null,
  created_at timestamptz not null default now()
);

create or replace function public._p2w_detect_auth_schema()
returns table(users_table text, balance_col text, sessions_table text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_users_tbl text;
  v_bal_col text;
  v_sessions_tbl text;
begin
  select format('%I.%I', t.table_schema, t.table_name),
         max(case when c.column_name in ('balance','coins','credits') then c.column_name end)
  into v_users_tbl, v_bal_col
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('referral_settings','user_referrals','referral_events','email_auth_accounts')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'id')
     and bool_or(c.column_name in ('balance','coins','credits'))
  order by (t.table_schema = 'public') desc, (t.table_name = 'users') desc, t.table_name
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
  order by (t.table_schema = 'public') desc, (t.table_name = 'sessions') desc, t.table_name
  limit 1;

  if v_users_tbl is null or v_sessions_tbl is null then
    raise exception 'Could not detect users or sessions table in Supabase.';
  end if;

  return query select v_users_tbl, coalesce(v_bal_col, 'balance'), v_sessions_tbl;
end;
$$;

create or replace function public.email_signup(
  p_email text,
  p_password text,
  p_name text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_schema record;
  v_users_schema text;
  v_users_name text;
  v_sess_schema text;
  v_sess_name text;
  v_email text;
  v_name text;
  v_pw_hash text;
  v_id_type text;
  v_user_id text;
  v_existing_id text;
  v_cols text[] := array[]::text[];
  v_vals text[] := array[]::text[];
  v_token text;
  v_sess_cols text := 'token, user_id';
  v_sess_vals text := '$1, $2';
begin
  v_email := lower(trim(coalesce(p_email, '')));
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    raise exception 'Valid Email ID enter karein.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'Password kam se kam 6 characters ka hona chahiye.';
  end if;

  if exists (select 1 from public.email_auth_accounts where email = v_email) then
    raise exception 'Is Email ID se account pehle se bana hai. Kripya Log in karein.';
  end if;

  select * into v_schema from public._p2w_detect_auth_schema();
  v_users_schema := replace(split_part(v_schema.users_table, '.', 1), '"', '');
  v_users_name := replace(split_part(v_schema.users_table, '.', 2), '"', '');
  v_sess_schema := replace(split_part(v_schema.sessions_table, '.', 1), '"', '');
  v_sess_name := replace(split_part(v_schema.sessions_table, '.', 2), '"', '');

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_users_schema and table_name = v_users_name and column_name = 'email'
  ) then
    execute format('select id::text from %s where lower(email) = $1 limit 1', v_schema.users_table)
      into v_existing_id using v_email;
    if v_existing_id is not null then
      raise exception 'Is Email ID se account pehle se bana hai. Kripya Log in karein.';
    end if;
  end if;

  v_name := trim(coalesce(p_name, ''));
  if v_name = '' then
    v_name := split_part(v_email, '@', 1);
  end if;

  v_pw_hash := crypt(p_password, gen_salt('bf'));

  select data_type into v_id_type
  from information_schema.columns
  where table_schema = v_users_schema and table_name = v_users_name and column_name = 'id';

  if v_id_type = 'uuid' then
    v_user_id := gen_random_uuid()::text;
    v_cols := array_append(v_cols, 'id');
    v_vals := array_append(v_vals, quote_literal(v_user_id) || '::uuid');
  else
    v_user_id := v_email;
    if exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'id') then
      execute format('select id::text from %s where lower(id::text) = $1 limit 1', v_schema.users_table)
        into v_existing_id using v_user_id;
      if v_existing_id is not null then
        raise exception 'Is Email ID se account pehle se bana hai. Kripya Log in karein.';
      end if;
    end if;
    v_cols := array_append(v_cols, 'id');
    v_vals := array_append(v_vals, quote_literal(v_user_id));
  end if;

  if exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'role') then
    v_cols := array_append(v_cols, 'role');
    v_vals := array_append(v_vals, quote_literal('user'));
  end if;

  v_cols := array_append(v_cols, format('%I', v_schema.balance_col));
  v_vals := array_append(v_vals, '20');

  if exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'email') then
    v_cols := array_append(v_cols, 'email');
    v_vals := array_append(v_vals, quote_literal(v_email));
  end if;

  if exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'display_name') then
    v_cols := array_append(v_cols, 'display_name');
    v_vals := array_append(v_vals, quote_literal(v_name));
  elsif exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'name') then
    v_cols := array_append(v_cols, 'name');
    v_vals := array_append(v_vals, quote_literal(v_name));
  end if;

  if exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'password_hash') then
    v_cols := array_append(v_cols, 'password_hash');
    v_vals := array_append(v_vals, quote_literal(v_pw_hash));
  elsif exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'pw_hash') then
    v_cols := array_append(v_cols, 'pw_hash');
    v_vals := array_append(v_vals, quote_literal(v_pw_hash));
  elsif exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'password') then
    v_cols := array_append(v_cols, 'password');
    v_vals := array_append(v_vals, quote_literal(v_pw_hash));
  end if;

  if exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'salt' and is_nullable = 'NO') then
    v_cols := array_append(v_cols, 'salt');
    v_vals := array_append(v_vals, quote_literal(''));
  end if;

  if exists (select 1 from information_schema.columns where table_schema = v_users_schema and table_name = v_users_name and column_name = 'phone' and is_nullable = 'NO') then
    v_cols := array_append(v_cols, 'phone');
    v_vals := array_append(v_vals, quote_literal(''));
  end if;

  execute format(
    'insert into %s (%s) values (%s)',
    v_schema.users_table,
    array_to_string(v_cols, ', '),
    array_to_string(v_vals, ', ')
  );

  insert into public.email_auth_accounts (email, user_id, display_name, password_hash)
  values (v_email, v_user_id, v_name, v_pw_hash);

  v_token := encode(gen_random_bytes(24), 'hex');

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_sess_schema and table_name = v_sess_name and column_name = 'expires_at'
  ) then
    v_sess_cols := v_sess_cols || ', expires_at';
    v_sess_vals := v_sess_vals || ', now() + interval ''30 days''';
  end if;

  if v_id_type = 'uuid' then
    execute format('insert into %s (%s) values (%s)', v_schema.sessions_table, v_sess_cols, replace(v_sess_vals, '$2', '$2::uuid'))
      using v_token, v_user_id;
  else
    execute format('insert into %s (%s) values (%s)', v_schema.sessions_table, v_sess_cols, v_sess_vals)
      using v_token, v_user_id;
  end if;

  return jsonb_build_object(
    'token', v_token,
    'id', v_user_id,
    'role', 'user',
    'email', v_email,
    'display_name', v_name
  );
end;
$$;

create or replace function public.email_login(
  p_email text,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_schema record;
  v_users_schema text;
  v_users_name text;
  v_sess_schema text;
  v_sess_name text;
  v_email text;
  v_acc public.email_auth_accounts;
  v_role text;
  v_name text;
  v_id_type text;
  v_token text;
  v_sess_cols text := 'token, user_id';
  v_sess_vals text := '$1, $2';
begin
  v_email := lower(trim(coalesce(p_email, '')));
  select * into v_acc from public.email_auth_accounts where email = v_email;
  if not found then
    raise exception 'Email ID ya Password galat hai.';
  end if;

  if v_acc.password_hash <> crypt(coalesce(p_password, ''), v_acc.password_hash) then
    raise exception 'Email ID ya Password galat hai.';
  end if;

  select * into v_schema from public._p2w_detect_auth_schema();
  v_users_schema := replace(split_part(v_schema.users_table, '.', 1), '"', '');
  v_users_name := replace(split_part(v_schema.users_table, '.', 2), '"', '');
  v_sess_schema := replace(split_part(v_schema.sessions_table, '.', 1), '"', '');
  v_sess_name := replace(split_part(v_schema.sessions_table, '.', 2), '"', '');

  execute format(
    'select coalesce(nullif(to_jsonb(u)->>''role'',''''), ''user''), coalesce(nullif(to_jsonb(u)->>''display_name'',''''), nullif(to_jsonb(u)->>''name'',''''), $2) from %s u where u.id::text = $1 limit 1',
    v_schema.users_table
  ) into v_role, v_name using v_acc.user_id, v_acc.display_name;

  if v_role is null then
    raise exception 'Account not found.';
  end if;

  select data_type into v_id_type
  from information_schema.columns
  where table_schema = v_users_schema and table_name = v_users_name and column_name = 'id';

  v_token := encode(gen_random_bytes(24), 'hex');
  if exists (
    select 1 from information_schema.columns
    where table_schema = v_sess_schema and table_name = v_sess_name and column_name = 'expires_at'
  ) then
    v_sess_cols := v_sess_cols || ', expires_at';
    v_sess_vals := v_sess_vals || ', now() + interval ''30 days''';
  end if;

  if v_id_type = 'uuid' then
    execute format('insert into %s (%s) values (%s)', v_schema.sessions_table, v_sess_cols, replace(v_sess_vals, '$2', '$2::uuid'))
      using v_token, v_acc.user_id;
  else
    execute format('insert into %s (%s) values (%s)', v_schema.sessions_table, v_sess_cols, v_sess_vals)
      using v_token, v_acc.user_id;
  end if;

  return jsonb_build_object(
    'token', v_token,
    'id', v_acc.user_id,
    'role', v_role,
    'email', v_acc.email,
    'display_name', coalesce(nullif(v_name, ''), v_acc.display_name, v_acc.email)
  );
end;
$$;

grant execute on function public.email_signup(text, text, text) to anon, authenticated;
grant execute on function public.email_login(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
