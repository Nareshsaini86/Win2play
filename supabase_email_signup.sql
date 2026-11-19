-- Play2Win Self-Service Email + Password Sign Up (with 6-Digit Email OTP Verification), Login & Password Change
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Includes:
--   1. public.email_smtp_settings table storing sender Gmail + password for OTP emails
--   2. public.email_signup_otps table storing 6-digit signup verification OTPs (10 min expiry, attempt limits)
--   3. request_signup_otp / verify_signup_otp_and_create RPCs (user is only created after 6-digit OTP verification)
--   4. email_login & email_change_password RPCs

create extension if not exists pgcrypto;

create table if not exists public.email_auth_accounts (
  email text primary key,
  user_id text not null unique,
  display_name text not null default '',
  password_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.email_smtp_settings (
  id integer primary key default 1 check (id = 1),
  sender_email text not null,
  smtp_password text not null,
  smtp_host text not null default 'smtp.gmail.com',
  smtp_port integer not null default 465,
  sender_name text not null default 'Play2Win',
  updated_at timestamptz not null default now()
);

insert into public.email_smtp_settings (id, sender_email, smtp_password, smtp_host, smtp_port, sender_name, updated_at)
values (1, 'supportplay2win@gmail.com', 'NSProl@8685', 'smtp.gmail.com', 465, 'Play2Win', now())
on conflict (id) do update
set sender_email = excluded.sender_email,
    smtp_password = excluded.smtp_password,
    smtp_host = excluded.smtp_host,
    smtp_port = excluded.smtp_port,
    sender_name = excluded.sender_name,
    updated_at = now();

create table if not exists public.email_signup_otps (
  email text primary key,
  otp_code text not null,
  display_name text not null default '',
  password_hash text not null,
  attempts integer not null default 0,
  expires_at timestamptz not null,
  last_sent_at timestamptz not null default now(),
  verified_at timestamptz
);

alter table public.email_auth_accounts enable row level security;
alter table public.email_smtp_settings enable row level security;
alter table public.email_signup_otps enable row level security;

revoke all on public.email_auth_accounts from anon, authenticated;
revoke all on public.email_smtp_settings from anon, authenticated;
revoke all on public.email_signup_otps from anon, authenticated;

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
    and t.table_name not in ('referral_settings','user_referrals','referral_events','email_auth_accounts','email_smtp_settings','email_signup_otps')
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
    raise exception 'Could not detect users or sessions table in Supabase.';
  end if;

  return query select v_users_tbl, coalesce(v_bal_col, 'balance'), v_sessions_tbl;
end;
$$;

-- Trigger helper so OAuth / Google logins that omit pw never fail app_users.pw NOT NULL
create or replace function public._p2w_fill_missing_pw_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.pw is null then
    new.pw := crypt(encode(gen_random_bytes(24), 'hex'), gen_salt('bf'));
  end if;
  return new;
end;
$$;

do $$
declare
  v_schema record;
  v_users_schema text;
  v_users_name text;
begin
  select * into v_schema from public._p2w_detect_auth_schema();
  v_users_schema := replace(split_part(v_schema.users_table, '.', 1), '"', '');
  v_users_name := replace(split_part(v_schema.users_table, '.', 2), '"', '');

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_users_schema and table_name = v_users_name and column_name = 'pw'
  ) then
    execute format('drop trigger if exists trg_p2w_fill_missing_pw on %s', v_schema.users_table);
    execute format(
      'create trigger trg_p2w_fill_missing_pw before insert on %s for each row execute function public._p2w_fill_missing_pw_before_insert()',
      v_schema.users_table
    );
  end if;
end;
$$;

create or replace function public._p2w_create_verified_email_user(
  p_email text,
  p_pw_hash text,
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
  v_id_type text;
  v_user_id text;
  v_existing_id text;
  v_cols text[];
  v_vals text[];
  v_col_rec record;
  v_token text;
  v_sess_cols text := 'token, user_id';
  v_sess_vals text := '$1, $2';
  v_candidates text[];
  v_cand text;
  v_inserted boolean := false;
  v_last_err text := '';
  v_check_def text := '';
begin
  v_email := lower(trim(coalesce(p_email, '')));
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    raise exception 'Please enter a valid Email ID.';
  end if;

  if exists (select 1 from public.email_auth_accounts where email = v_email) then
    raise exception 'An account with this Email ID already exists. Please log in.';
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
      raise exception 'An account with this Email ID already exists. Please log in.';
    end if;
  end if;

  v_name := trim(coalesce(p_name, ''));
  if v_name = '' then
    v_name := split_part(v_email, '@', 1);
  end if;

  select data_type into v_id_type
  from information_schema.columns
  where table_schema = v_users_schema and table_name = v_users_name and column_name = 'id';

  if v_id_type = 'uuid' then
    v_candidates := array[gen_random_uuid()::text];
  else
    v_candidates := array[
      'u' || substr(md5(v_email || ':' || clock_timestamp()::text || random()::text), 1, 7),
      'u' || substr(md5(v_email || ':' || random()::text), 1, 5),
      'user_' || substr(md5(v_email || ':' || random()::text), 1, 6),
      'g_' || substr(md5(v_email || ':' || random()::text), 1, 8),
      'p2w' || substr(md5(v_email || ':' || random()::text), 1, 6),
      floor(10000000 + random() * 89999999)::bigint::text,
      'u' || substr(md5(v_email || ':' || random()::text), 1, 11)
    ];
  end if;

  foreach v_cand in array v_candidates
  loop
    v_user_id := v_cand;
    v_cols := array[]::text[];
    v_vals := array[]::text[];

    for v_col_rec in
      select column_name, data_type, is_nullable, column_default, is_identity, is_generated
      from information_schema.columns
      where table_schema = v_users_schema and table_name = v_users_name
      order by ordinal_position
    loop
      if v_col_rec.is_identity = 'YES' or v_col_rec.is_generated = 'ALWAYS' then
        continue;
      end if;

      if v_col_rec.column_name = 'id' then
        v_cols := array_append(v_cols, 'id');
        if v_id_type = 'uuid' then
          v_vals := array_append(v_vals, quote_literal(v_user_id) || '::uuid');
        else
          v_vals := array_append(v_vals, quote_literal(v_user_id));
        end if;
      elsif v_col_rec.column_name = 'role' then
        v_cols := array_append(v_cols, 'role');
        v_vals := array_append(v_vals, quote_literal('user'));
      elsif v_col_rec.column_name = v_schema.balance_col then
        v_cols := array_append(v_cols, format('%I', v_schema.balance_col));
        v_vals := array_append(v_vals, '20');
      elsif v_col_rec.column_name = 'email' then
        v_cols := array_append(v_cols, 'email');
        v_vals := array_append(v_vals, quote_literal(v_email));
      elsif v_col_rec.column_name in ('display_name', 'name', 'full_name') then
        v_cols := array_append(v_cols, format('%I', v_col_rec.column_name));
        v_vals := array_append(v_vals, quote_literal(v_name));
      elsif v_col_rec.column_name in ('pw', 'password_hash', 'pw_hash', 'password') then
        v_cols := array_append(v_cols, format('%I', v_col_rec.column_name));
        v_vals := array_append(v_vals, quote_literal(p_pw_hash));
      elsif v_col_rec.column_name = 'salt' then
        v_cols := array_append(v_cols, 'salt');
        v_vals := array_append(v_vals, quote_literal(''));
      elsif v_col_rec.column_name in ('auth_provider', 'provider') then
        v_cols := array_append(v_cols, format('%I', v_col_rec.column_name));
        v_vals := array_append(v_vals, quote_literal('email'));
      elsif v_col_rec.is_nullable = 'NO' and v_col_rec.column_default is null then
        v_cols := array_append(v_cols, format('%I', v_col_rec.column_name));
        if v_col_rec.data_type = 'boolean' then
          v_vals := array_append(v_vals, 'false');
        elsif v_col_rec.data_type in ('integer', 'bigint', 'smallint', 'numeric', 'real', 'double precision') then
          v_vals := array_append(v_vals, '0');
        elsif v_col_rec.data_type = 'uuid' then
          v_vals := array_append(v_vals, quote_literal(gen_random_uuid()::text) || '::uuid');
        elsif v_col_rec.data_type in ('timestamp with time zone', 'timestamp without time zone') then
          v_vals := array_append(v_vals, 'now()');
        elsif v_col_rec.data_type = 'date' then
          v_vals := array_append(v_vals, 'current_date');
        elsif v_col_rec.data_type = 'jsonb' then
          v_vals := array_append(v_vals, '''{}''::jsonb');
        elsif v_col_rec.data_type = 'json' then
          v_vals := array_append(v_vals, '''{}''::json');
        else
          v_vals := array_append(v_vals, quote_literal(''));
        end if;
      end if;
    end loop;

    begin
      execute format(
        'insert into %s (%s) values (%s)',
        v_schema.users_table,
        array_to_string(v_cols, ', '),
        array_to_string(v_vals, ', ')
      );
      v_inserted := true;
      exit;
    exception
      when check_violation or unique_violation then
        if position('email' in lower(sqlerrm)) > 0 then
          raise exception 'An account with this Email ID already exists. Please log in.';
        end if;
        v_last_err := sqlerrm;
    end;
  end loop;

  if not v_inserted then
    select string_agg(conname || ': ' || pg_get_constraintdef(c.oid), '; ')
    into v_check_def
    from pg_constraint c
    join pg_class r on r.oid = c.conrelid
    join pg_namespace n on n.oid = r.relnamespace
    where n.nspname = v_users_schema and r.relname = v_users_name and c.contype = 'c';

    raise exception '% (constraints: %)', coalesce(nullif(v_last_err, ''), 'Could not insert user'), coalesce(v_check_def, 'none');
  end if;

  insert into public.email_auth_accounts (email, user_id, display_name, password_hash)
  values (v_email, v_user_id, v_name, p_pw_hash);

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

create or replace function public.request_signup_otp(
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
  v_email text;
  v_name text;
  v_pw_hash text;
  v_existing_id text;
  v_prev public.email_signup_otps;
  v_smtp public.email_smtp_settings;
  v_rand bytea;
  v_rand_num bigint;
  v_otp text;
begin
  v_email := lower(trim(coalesce(p_email, '')));
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    raise exception 'Please enter a valid Email ID.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'Password must be at least 6 characters.';
  end if;

  if exists (select 1 from public.email_auth_accounts where email = v_email) then
    raise exception 'An account with this Email ID already exists. Please log in.';
  end if;

  select * into v_schema from public._p2w_detect_auth_schema();
  v_users_schema := replace(split_part(v_schema.users_table, '.', 1), '"', '');
  v_users_name := replace(split_part(v_schema.users_table, '.', 2), '"', '');

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_users_schema and table_name = v_users_name and column_name = 'email'
  ) then
    execute format('select id::text from %s where lower(email) = $1 limit 1', v_schema.users_table)
      into v_existing_id using v_email;
    if v_existing_id is not null then
      raise exception 'An account with this Email ID already exists. Please log in.';
    end if;
  end if;

  select * into v_prev from public.email_signup_otps where email = v_email;
  if found and v_prev.last_sent_at > now() - interval '25 seconds' then
    return jsonb_build_object(
      'success', false,
      'message', 'Please wait ' || greatest(1, ceil(extract(epoch from (v_prev.last_sent_at + interval '25 seconds' - now())))::int) || 's before requesting another OTP.'
    );
  end if;

  select * into v_smtp from public.email_smtp_settings where id = 1;
  if not found or coalesce(v_smtp.sender_email, '') = '' or coalesce(v_smtp.smtp_password, '') = '' then
    raise exception 'Email sender settings are missing in database (email_smtp_settings).';
  end if;

  v_name := trim(coalesce(p_name, ''));
  if v_name = '' then
    v_name := split_part(v_email, '@', 1);
  end if;

  v_pw_hash := crypt(p_password, gen_salt('bf'));
  v_rand := gen_random_bytes(4);
  v_rand_num := (
    get_byte(v_rand, 0)::bigint * 16777216 +
    get_byte(v_rand, 1)::bigint * 65536 +
    get_byte(v_rand, 2)::bigint * 256 +
    get_byte(v_rand, 3)::bigint
  ) % 900000;
  v_otp := lpad((100000 + v_rand_num)::text, 6, '0');

  insert into public.email_signup_otps (email, otp_code, display_name, password_hash, attempts, expires_at, last_sent_at, verified_at)
  values (v_email, v_otp, v_name, v_pw_hash, 0, now() + interval '10 minutes', now(), null)
  on conflict (email) do update
  set otp_code = excluded.otp_code,
      display_name = excluded.display_name,
      password_hash = excluded.password_hash,
      attempts = 0,
      expires_at = excluded.expires_at,
      last_sent_at = now(),
      verified_at = null;

  return jsonb_build_object(
    'ok', true,
    'email', v_email,
    'display_name', v_name,
    'otp', v_otp,
    'expires_in_sec', 600,
    'smtp', jsonb_build_object(
      'host', v_smtp.smtp_host,
      'port', v_smtp.smtp_port,
      'sender_email', v_smtp.sender_email,
      'sender_name', v_smtp.sender_name,
      'smtp_password', v_smtp.smtp_password
    )
  );
end;
$$;

create or replace function public.verify_signup_otp_and_create(
  p_email text,
  p_otp text,
  p_password text default null,
  p_name text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text;
  v_otp text;
  v_rec public.email_signup_otps;
  v_pw_hash text;
  v_name text;
  v_res jsonb;
begin
  v_email := lower(trim(coalesce(p_email, '')));
  v_otp := regexp_replace(trim(coalesce(p_otp, '')), '\s+', '', 'g');

  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    return jsonb_build_object('success', false, 'message', 'Please enter a valid Email ID.');
  end if;

  if v_otp !~ '^\d{6}$' then
    return jsonb_build_object('success', false, 'message', 'Please enter the 6-digit OTP sent to your email.');
  end if;

  select * into v_rec from public.email_signup_otps where email = v_email;
  if not found then
    return jsonb_build_object('success', false, 'message', 'No active OTP found for this email. Please tap Send OTP first.');
  end if;

  if v_rec.expires_at < now() then
    return jsonb_build_object('success', false, 'message', 'OTP has expired. Please tap Resend OTP.');
  end if;

  if v_rec.attempts >= 5 then
    return jsonb_build_object('success', false, 'message', 'Too many incorrect OTP attempts. Please request a new OTP.');
  end if;

  if v_rec.otp_code <> v_otp then
    update public.email_signup_otps
    set attempts = attempts + 1
    where email = v_email;
    return jsonb_build_object(
      'success', false,
      'message', 'Invalid 6-digit OTP. ' || greatest(0, 4 - v_rec.attempts) || ' attempts left.'
    );
  end if;

  v_pw_hash := case
    when length(coalesce(p_password, '')) >= 6 then crypt(p_password, gen_salt('bf'))
    else v_rec.password_hash
  end;
  v_name := coalesce(nullif(trim(coalesce(p_name, '')), ''), nullif(v_rec.display_name, ''), split_part(v_email, '@', 1));

  v_res := public._p2w_create_verified_email_user(v_email, v_pw_hash, v_name);
  delete from public.email_signup_otps where email = v_email;

  return v_res;
end;
$$;

drop function if exists public.email_signup(text, text, text);

create or replace function public.email_signup(
  p_email text,
  p_password text,
  p_name text default '',
  p_otp text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if trim(coalesce(p_otp, '')) = '' then
    return jsonb_build_object(
      'success', false,
      'otp_required', true,
      'message', 'Email OTP verification is required before creating a new account.'
    );
  end if;

  return public.verify_signup_otp_and_create(p_email, p_otp, p_password, p_name);
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
    raise exception 'Invalid Email ID or password.';
  end if;

  if v_acc.password_hash <> crypt(coalesce(p_password, ''), v_acc.password_hash) then
    raise exception 'Invalid Email ID or password.';
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

create or replace function public.email_change_password(
  p_token text,
  p_old text,
  p_new text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_schema record;
  v_sess_schema text;
  v_sess_name text;
  v_users_schema text;
  v_users_name text;
  v_uid text;
  v_acc public.email_auth_accounts;
  v_new_hash text;
begin
  if length(coalesce(p_new, '')) < 6 then
    raise exception 'New password must be at least 6 characters.';
  end if;

  select * into v_schema from public._p2w_detect_auth_schema();
  v_sess_schema := replace(split_part(v_schema.sessions_table, '.', 1), '"', '');
  v_sess_name := replace(split_part(v_schema.sessions_table, '.', 2), '"', '');
  v_users_schema := replace(split_part(v_schema.users_table, '.', 1), '"', '');
  v_users_name := replace(split_part(v_schema.users_table, '.', 2), '"', '');

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

  select * into v_acc from public.email_auth_accounts where user_id = v_uid limit 1;
  if not found then
    raise exception 'Email password account not found.';
  end if;

  if v_acc.password_hash <> crypt(coalesce(p_old, ''), v_acc.password_hash) then
    raise exception 'Current password is incorrect.';
  end if;

  v_new_hash := crypt(p_new, gen_salt('bf'));
  update public.email_auth_accounts set password_hash = v_new_hash where email = v_acc.email;

  if exists (
    select 1 from information_schema.columns
    where table_schema = v_users_schema and table_name = v_users_name and column_name = 'pw'
  ) then
    execute format('update %s set pw = $1 where id::text = $2', v_schema.users_table)
      using v_new_hash, v_uid;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.request_signup_otp(text, text, text) to anon, authenticated;
grant execute on function public.verify_signup_otp_and_create(text, text, text, text) to anon, authenticated;
grant execute on function public.email_signup(text, text, text, text) to anon, authenticated;
grant execute on function public.email_login(text, text) to anon, authenticated;
grant execute on function public.email_change_password(text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
