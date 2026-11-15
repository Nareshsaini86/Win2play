-- Play2Win Aviator + Admin Multi-Game Live Bets (Supabase SQL Migration)
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Aviator Crash Rules:
--   * No bet placed in round (total_stake = 0): crashes between 25.00x and 50.00x
--   * Bet placed up to 500 Coins (1..500): max crash capped at 25.00x
--   * Bet placed over 500 Coins (> 500): max crash capped at 1.10x
-- Admin Live Bets RPCs:
--   * admin_gold_bets(p_token): Gold Ball live/recent bets, user, amount, win/loss & payout
--   * admin_aviator_bets(p_token): Aviator current round + recent bets, cashout & crash

create table if not exists public.aviator_global_rounds (
  id bigserial primary key,
  betting_ends_at timestamptz not null,
  crash_point numeric(10, 2) not null check (crash_point >= 1.00),
  fly_seconds double precision not null,
  crashes_at timestamptz not null,
  next_round_at timestamptz not null,
  crash_finalized boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);

alter table public.aviator_global_rounds add column if not exists crash_finalized boolean not null default true;

create table if not exists public.aviator_bets (
  id bigserial primary key,
  round_id bigint not null references public.aviator_global_rounds(id) on delete cascade,
  user_id text not null,
  stake integer not null check (stake >= 1 and stake <= 1000),
  auto_cashout numeric(10, 2),
  cashout_mult numeric(10, 2),
  payout integer not null default 0,
  status text not null default 'active' check (status in ('active', 'cashed_out', 'lost')),
  created_at timestamptz not null default clock_timestamp(),
  settled_at timestamptz,
  unique (round_id, user_id)
);

create index if not exists idx_aviator_global_rounds_crashes on public.aviator_global_rounds (crashes_at desc, id desc);
create index if not exists idx_aviator_bets_user on public.aviator_bets (user_id, id desc);
create index if not exists idx_aviator_bets_round on public.aviator_bets (round_id, status);

create or replace function public._p2w_aviator_detect_schema()
returns table(users_table text, balance_col text, sessions_table text, coin_log_table text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_users_tbl text;
  v_bal_col text;
  v_sessions_tbl text;
  v_coin_log_tbl text;
begin
  select format('%I.%I', t.table_schema, t.table_name),
         max(case when c.column_name in ('balance','coins','credits') then c.column_name end)
  into v_users_tbl, v_bal_col
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('referral_settings','user_referrals','referral_events','email_auth_accounts','aviator_rounds','aviator_global_rounds','aviator_bets')
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
    and t.table_name not in ('referral_settings','user_referrals','referral_events','email_auth_accounts','aviator_rounds','aviator_global_rounds','aviator_bets')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'user_id')
     and bool_or(c.column_name = 'amount')
     and bool_or(c.column_name = 'created_at')
     and not bool_or(c.column_name in ('target','utr','upi_id','round','payout'))
  order by (t.table_schema = 'public') desc, (t.table_name in ('coin_log','app_coin_log')) desc, t.table_name
  limit 1;

  if v_users_tbl is null or v_sessions_tbl is null then
    raise exception 'Could not detect users or sessions table in Supabase.';
  end if;

  return query select v_users_tbl, coalesce(v_bal_col, 'balance'), v_sessions_tbl, v_coin_log_tbl;
end;
$$;

create or replace function public._p2w_aviator_auth(p_token text)
returns table(user_id text, user_role text, balance bigint, users_table text, balance_col text, coin_log_table text)
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
  v_bal bigint;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Session expired. Please log in again.';
  end if;

  select * into v_schema from public._p2w_aviator_detect_schema();
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
    'select coalesce(nullif(to_jsonb(u)->>''role'',''''), case when coalesce((to_jsonb(u)->>''is_admin'')::boolean, false) then ''admin'' else ''user'' end), coalesce(%I, 0)::bigint from %s u where u.id::text = $1 limit 1',
    v_schema.balance_col,
    v_schema.users_table
  ) into v_role, v_bal using v_uid;

  if v_role is null then
    raise exception 'Account not found.';
  end if;

  return query select v_uid, v_role, coalesce(v_bal, 0), v_schema.users_table, v_schema.balance_col, v_schema.coin_log_table;
end;
$$;

create or replace function public._p2w_aviator_log_coin(
  p_coin_log_table text,
  p_user_id text,
  p_amount integer,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_log_schema text;
  v_log_name text;
  v_reason_col text;
begin
  if p_coin_log_table is null or p_amount = 0 then
    return;
  end if;

  v_log_schema := replace(split_part(p_coin_log_table, '.', 1), '"', '');
  v_log_name := replace(split_part(p_coin_log_table, '.', 2), '"', '');

  select column_name into v_reason_col
  from information_schema.columns
  where table_schema = v_log_schema and table_name = v_log_name
    and column_name in ('reason', 'note', 'description', 'type')
  order by case column_name when 'reason' then 1 when 'note' then 2 when 'description' then 3 else 4 end
  limit 1;

  if v_reason_col is not null then
    execute format('insert into %s (user_id, amount, %I, created_at) values ($1, $2, $3, now())', p_coin_log_table, v_reason_col)
      using p_user_id, p_amount, p_reason;
  else
    execute format('insert into %s (user_id, amount, created_at) values ($1, $2, now())', p_coin_log_table)
      using p_user_id, p_amount;
  end if;
exception when others then
  null;
end;
$$;

-- Synchronize & advance global Aviator rounds:
-- Finalizes crash_point right when 10s betting closes based on total staked in that round:
--   * 0 Coins bet -> 25.00x .. 50.00x
--   * 1..500 Coins bet -> capped at <= 25.00x
--   * > 500 Coins bet -> capped at <= 1.10x
create or replace function public._p2w_aviator_ensure_round(
  p_users_table text,
  p_balance_col text,
  p_coin_log_table text
)
returns public.aviator_global_rounds
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_round public.aviator_global_rounds;
  v_has_round boolean := false;
  v_bet record;
  v_payout integer;
  v_r double precision;
  v_total_stake bigint;
  v_crash_point numeric(10, 2);
  v_fly_secs double precision;
  v_betting_ends timestamptz;
  v_crashes_at timestamptz;
  v_next_round timestamptz;
begin
  perform pg_advisory_xact_lock(92847103);

  select * into v_round
  from public.aviator_global_rounds
  order by id desc
  limit 1;
  v_has_round := found;

  -- Finalize crash_point as soon as betting closes for the active round
  if v_has_round and not v_round.crash_finalized and v_now >= v_round.betting_ends_at then
    select coalesce(sum(stake), 0)
    into v_total_stake
    from public.aviator_bets
    where round_id = v_round.id;

    v_r := random();
    if coalesce(v_total_stake, 0) = 0 then
      -- No bet in this round: 25.00x to 50.00x
      v_crash_point := least(50.00, greatest(25.00, round((25.00 + v_r * 25.00)::numeric, 2)));
    elsif v_total_stake > 500 then
      -- Bet over 500 Coins: never above 1.10x
      if v_r < 0.25 then
        v_crash_point := 1.00;
      else
        v_crash_point := least(1.10, greatest(1.01, round((1.01 + random() * 0.09)::numeric, 2)));
      end if;
    else
      -- Normal bet (1..500 Coins): max 25.00x
      if v_r < 0.05 then
        v_crash_point := 1.00;
      else
        v_crash_point := least(25.00, greatest(1.02, round((0.96 / greatest(0.038, 1.0 - v_r))::numeric, 2)));
      end if;
    end if;

    if v_crash_point <= 1.00 then
      v_fly_secs := 0.90;
    else
      v_fly_secs := greatest(1.10, ln(v_crash_point::double precision) / 0.11);
    end if;

    v_crashes_at := v_round.betting_ends_at + make_interval(secs => v_fly_secs);
    v_next_round := v_crashes_at + interval '2.5 seconds';

    update public.aviator_global_rounds
    set crash_point = v_crash_point,
        fly_seconds = v_fly_secs,
        crashes_at = v_crashes_at,
        next_round_at = v_next_round,
        crash_finalized = true
    where id = v_round.id
    returning * into v_round;
  end if;

  -- Settle any active bets whose round has already crashed (honoring auto_cashout if reached before crash)
  for v_bet in
    select b.id, b.user_id, b.stake, b.auto_cashout, r.crash_point, r.crashes_at
    from public.aviator_bets b
    join public.aviator_global_rounds r on r.id = b.round_id
    where b.status = 'active' and r.crash_finalized and r.crashes_at <= v_now
    for update of b
  loop
    if v_bet.auto_cashout is not null
       and v_bet.auto_cashout >= 1.05
       and v_bet.auto_cashout <= v_bet.crash_point
       and v_bet.crash_point > 1.00 then
      v_payout := greatest(v_bet.stake, floor(v_bet.stake * v_bet.auto_cashout)::integer);
      update public.aviator_bets
      set status = 'cashed_out',
          cashout_mult = v_bet.auto_cashout,
          payout = v_payout,
          settled_at = v_now
      where id = v_bet.id;

      execute format(
        'update %s set %I = coalesce(%I, 0) + $1 where id::text = $2',
        p_users_table, p_balance_col, p_balance_col
      ) using v_payout, v_bet.user_id;

      perform public._p2w_aviator_log_coin(
        p_coin_log_table,
        v_bet.user_id,
        v_payout,
        format('Aviator auto win @ %sx', v_bet.auto_cashout)
      );
    else
      update public.aviator_bets
      set status = 'lost',
          payout = 0,
          settled_at = v_now
      where id = v_bet.id;
    end if;
  end loop;

  if not v_has_round or (v_round.crash_finalized and v_now >= v_round.next_round_at) then
    v_betting_ends := v_now + interval '10 seconds';
    v_crashes_at := v_betting_ends + interval '2 seconds';
    v_next_round := v_crashes_at + interval '2.5 seconds';

    insert into public.aviator_global_rounds (
      betting_ends_at, crash_point, fly_seconds, crashes_at, next_round_at, crash_finalized
    )
    values (
      v_betting_ends, 1.00, 2.0, v_crashes_at, v_next_round, false
    )
    returning * into v_round;
  end if;

  return v_round;
end;
$$;

create or replace function public.aviator_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_round public.aviator_global_rounds;
  v_now timestamptz;
  v_phase text;
  v_bet_left_ms bigint;
  v_fly_elapsed_ms bigint;
  v_crash_left_ms bigint;
  v_next_left_ms bigint;
  v_my_bet jsonb;
  v_results jsonb;
  v_my_bets jsonb;
  v_fresh_bal bigint;
begin
  select * into v_auth from public._p2w_aviator_auth(p_token);
  v_round := public._p2w_aviator_ensure_round(v_auth.users_table, v_auth.balance_col, v_auth.coin_log_table);
  v_now := clock_timestamp();

  execute format('select coalesce(%I, 0)::bigint from %s where id::text = $1', v_auth.balance_col, v_auth.users_table)
    into v_fresh_bal using v_auth.user_id;

  if v_now < v_round.betting_ends_at then
    v_phase := 'betting';
  elsif v_now < v_round.crashes_at then
    v_phase := 'flying';
  else
    v_phase := 'crashed';
  end if;

  v_bet_left_ms := greatest(0, round(extract(epoch from (v_round.betting_ends_at - v_now)) * 1000))::bigint;
  v_fly_elapsed_ms := greatest(0, round(extract(epoch from (v_now - v_round.betting_ends_at)) * 1000))::bigint;
  v_crash_left_ms := greatest(0, round(extract(epoch from (v_round.crashes_at - v_now)) * 1000))::bigint;
  v_next_left_ms := greatest(0, round(extract(epoch from (v_round.next_round_at - v_now)) * 1000))::bigint;

  select row_to_json(t)::jsonb into v_my_bet
  from (
    select id, round_id, stake, auto_cashout, cashout_mult, payout, status
    from public.aviator_bets
    where round_id = v_round.id and user_id = v_auth.user_id
    limit 1
  ) t;

  select coalesce(jsonb_agg(row_to_json(r)), '[]'::jsonb)
  into v_results
  from (
    select id as round_id, crash_point, crashes_at
    from public.aviator_global_rounds
    where crash_finalized and crashes_at <= v_now
    order by id desc
    limit 20
  ) r;

  select coalesce(jsonb_agg(row_to_json(b)), '[]'::jsonb)
  into v_my_bets
  from (
    select
      ab.id,
      ab.round_id,
      ab.stake,
      ab.auto_cashout,
      ab.cashout_mult,
      ab.payout,
      ab.status,
      case when gr.crash_finalized and gr.crashes_at <= v_now then gr.crash_point else null end as crash_point,
      ab.created_at
    from public.aviator_bets ab
    join public.aviator_global_rounds gr on gr.id = ab.round_id
    where ab.user_id = v_auth.user_id
    order by ab.id desc
    limit 20
  ) b;

  return jsonb_build_object(
    'balance', coalesce(v_fresh_bal, v_auth.balance),
    'min_bet', 1,
    'max_bet', 1000,
    'server_now', v_now,
    'phase', v_phase,
    'bet_left_ms', v_bet_left_ms,
    'fly_elapsed_ms', v_fly_elapsed_ms,
    'crash_left_ms', v_crash_left_ms,
    'next_left_ms', v_next_left_ms,
    'round', jsonb_build_object(
      'id', v_round.id,
      'betting_ends_at', v_round.betting_ends_at,
      'crashes_at', v_round.crashes_at,
      'next_round_at', v_round.next_round_at,
      'crash_point', case when v_round.crash_finalized and v_phase in ('flying', 'crashed') then v_round.crash_point else null end
    ),
    'my_bet', v_my_bet,
    'results', v_results,
    'my_bets', v_my_bets
  );
end;
$$;

create or replace function public.aviator_place_bet(
  p_token text,
  p_round_id bigint,
  p_amount integer,
  p_auto_cashout numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_round public.aviator_global_rounds;
  v_now timestamptz;
  v_auto numeric(10, 2);
  v_new_balance bigint;
  v_bet public.aviator_bets;
begin
  select * into v_auth from public._p2w_aviator_auth(p_token);
  if v_auth.user_role = 'admin' then
    raise exception 'Admin accounts cannot play Aviator.';
  end if;

  v_round := public._p2w_aviator_ensure_round(v_auth.users_table, v_auth.balance_col, v_auth.coin_log_table);
  v_now := clock_timestamp();

  if p_round_id is null or p_round_id <> v_round.id then
    if v_now < v_round.betting_ends_at then
      raise exception 'Naya round #%s shuru ho gaya hai, dobara bet lagayein.', v_round.id;
    else
      raise exception 'Betting band hai! Plane ud raha hai, agle round ka wait karein.';
    end if;
  end if;

  if v_now >= v_round.betting_ends_at then
    raise exception 'Betting band hai! Plane ud raha hai, agle round ka wait karein.';
  end if;

  if p_amount is null or p_amount < 1 or p_amount > 1000 then
    raise exception 'Bet amount 1 se 1,000 Coins ke beech hona chahiye.';
  end if;

  if p_auto_cashout is not null then
    v_auto := round(p_auto_cashout, 2);
    if v_auto < 1.05 or v_auto > 100.00 then
      raise exception 'Auto cashout 1.05x se 100.00x ke beech hona chahiye.';
    end if;
  else
    v_auto := null;
  end if;

  if exists (select 1 from public.aviator_bets where round_id = v_round.id and user_id = v_auth.user_id) then
    raise exception 'Is round me aapki bet pehle se lagi hai.';
  end if;

  execute format(
    'update %s set %I = coalesce(%I, 0) - $1 where id::text = $2 and coalesce(%I, 0) >= $1 returning %I::bigint',
    v_auth.users_table, v_auth.balance_col, v_auth.balance_col, v_auth.balance_col, v_auth.balance_col
  ) into v_new_balance using p_amount, v_auth.user_id;

  if v_new_balance is null then
    raise exception 'Insufficient coins balance.';
  end if;

  perform public._p2w_aviator_log_coin(
    v_auth.coin_log_table,
    v_auth.user_id,
    -p_amount,
    format('Aviator bet Round #%s', v_round.id)
  );

  insert into public.aviator_bets (round_id, user_id, stake, auto_cashout, status)
  values (v_round.id, v_auth.user_id, p_amount, v_auto, 'active')
  returning * into v_bet;

  return jsonb_build_object(
    'bet_id', v_bet.id,
    'round_id', v_bet.round_id,
    'stake', v_bet.stake,
    'auto_cashout', v_bet.auto_cashout,
    'status', v_bet.status,
    'balance', v_new_balance
  );
end;
$$;

create or replace function public.aviator_cashout(
  p_token text,
  p_round_id bigint,
  p_claim_mult numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_round public.aviator_global_rounds;
  v_bet public.aviator_bets;
  v_now timestamptz;
  v_elapsed double precision;
  v_time_mult numeric(10, 2);
  v_mult numeric(10, 2);
  v_payout integer;
  v_new_balance bigint;
begin
  select * into v_auth from public._p2w_aviator_auth(p_token);
  perform public._p2w_aviator_ensure_round(v_auth.users_table, v_auth.balance_col, v_auth.coin_log_table);

  select * into v_round from public.aviator_global_rounds where id = p_round_id;
  if not found then
    raise exception 'Round not found.';
  end if;

  select * into v_bet
  from public.aviator_bets
  where round_id = p_round_id and user_id = v_auth.user_id
  for update;

  if not found then
    raise exception 'Is round me aapki koi bet nahi hai.';
  end if;

  if v_bet.status = 'cashed_out' then
    execute format('select coalesce(%I, 0)::bigint from %s where id::text = $1', v_auth.balance_col, v_auth.users_table)
      into v_new_balance using v_auth.user_id;
    return jsonb_build_object(
      'won', true,
      'crashed', v_round.crash_finalized and clock_timestamp() >= v_round.crashes_at,
      'round_id', v_round.id,
      'cashout_mult', v_bet.cashout_mult,
      'payout', v_bet.payout,
      'balance', coalesce(v_new_balance, v_auth.balance)
    );
  end if;

  if v_bet.status = 'lost' then
    execute format('select coalesce(%I, 0)::bigint from %s where id::text = $1', v_auth.balance_col, v_auth.users_table)
      into v_new_balance using v_auth.user_id;
    return jsonb_build_object(
      'won', false,
      'crashed', true,
      'round_id', v_round.id,
      'crash_point', v_round.crash_point,
      'payout', 0,
      'balance', coalesce(v_new_balance, v_auth.balance)
    );
  end if;

  v_now := clock_timestamp();
  if v_now < v_round.betting_ends_at or not v_round.crash_finalized then
    raise exception 'Plane abhi take off nahi hua hai.';
  end if;

  if v_round.crash_point <= 1.00 or v_now > (v_round.crashes_at + interval '0.55 seconds') then
    update public.aviator_bets
    set status = 'lost',
        payout = 0,
        settled_at = v_now
    where id = v_bet.id;

    return jsonb_build_object(
      'won', false,
      'crashed', true,
      'round_id', v_round.id,
      'crash_point', v_round.crash_point,
      'payout', 0,
      'balance', v_auth.balance
    );
  end if;

  v_elapsed := greatest(0.0, extract(epoch from (v_now - v_round.betting_ends_at)));
  v_time_mult := least(50.00, round(exp(0.11 * least(v_elapsed + 0.25, 42.0))::numeric, 2));
  if p_claim_mult is not null and p_claim_mult >= 1.01 then
    v_mult := least(round(p_claim_mult, 2), v_time_mult, v_round.crash_point);
  else
    v_mult := least(v_time_mult, v_round.crash_point);
  end if;
  v_mult := greatest(1.01, least(v_mult, v_round.crash_point));

  v_payout := greatest(v_bet.stake, floor(v_bet.stake * v_mult)::integer);

  update public.aviator_bets
  set status = 'cashed_out',
      cashout_mult = v_mult,
      payout = v_payout,
      settled_at = v_now
  where id = v_bet.id;

  execute format(
    'update %s set %I = coalesce(%I, 0) + $1 where id::text = $2 returning %I::bigint',
    v_auth.users_table, v_auth.balance_col, v_auth.balance_col, v_auth.balance_col
  ) into v_new_balance using v_payout, v_auth.user_id;

  perform public._p2w_aviator_log_coin(
    v_auth.coin_log_table,
    v_auth.user_id,
    v_payout,
    format('Aviator win Round #%s @ %sx', v_round.id, v_mult)
  );

  return jsonb_build_object(
    'won', true,
    'crashed', false,
    'round_id', v_round.id,
    'cashout_mult', v_mult,
    'payout', v_payout,
    'balance', coalesce(v_new_balance, v_auth.balance + v_payout)
  );
end;
$$;

-- Admin: live & recent Aviator bets
create or replace function public.admin_aviator_bets(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_round public.aviator_global_rounds;
  v_now timestamptz;
  v_phase text;
  v_total_staked bigint;
  v_current jsonb;
  v_recent jsonb;
begin
  select * into v_auth from public._p2w_aviator_auth(p_token);
  if v_auth.user_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  v_round := public._p2w_aviator_ensure_round(v_auth.users_table, v_auth.balance_col, v_auth.coin_log_table);
  v_now := clock_timestamp();

  if v_now < v_round.betting_ends_at then
    v_phase := 'betting';
  elsif v_now < v_round.crashes_at then
    v_phase := 'flying';
  else
    v_phase := 'crashed';
  end if;

  select coalesce(sum(stake), 0)
  into v_total_staked
  from public.aviator_bets
  where round_id = v_round.id;

  execute format($q$
    select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    from (
      select
        ab.id,
        ab.round_id,
        ab.user_id,
        coalesce(nullif(to_jsonb(u)->>'display_name',''), nullif(to_jsonb(u)->>'email',''), ab.user_id) as user_label,
        ab.stake,
        ab.auto_cashout,
        ab.cashout_mult,
        ab.payout,
        ab.status
      from public.aviator_bets ab
      left join %s u on u.id::text = ab.user_id
      where ab.round_id = $1
      order by ab.id desc
    ) t
  $q$, v_auth.users_table) into v_current using v_round.id;

  execute format($q$
    select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    from (
      select
        ab.id,
        ab.round_id,
        ab.user_id,
        coalesce(nullif(to_jsonb(u)->>'display_name',''), nullif(to_jsonb(u)->>'email',''), ab.user_id) as user_label,
        ab.stake,
        ab.cashout_mult,
        ab.payout,
        ab.status,
        case when gr.crash_finalized and gr.crashes_at <= $1 then gr.crash_point else null end as crash_point,
        ab.created_at
      from public.aviator_bets ab
      join public.aviator_global_rounds gr on gr.id = ab.round_id
      left join %s u on u.id::text = ab.user_id
      order by ab.id desc
      limit 40
    ) t
  $q$, v_auth.users_table) into v_recent using v_now;

  return jsonb_build_object(
    'round_id', v_round.id,
    'phase', v_phase,
    'crash_point', case when v_round.crash_finalized and v_phase in ('flying','crashed') then v_round.crash_point else null end,
    'total_staked', coalesce(v_total_staked, 0),
    'current', v_current,
    'recent', v_recent
  );
end;
$$;

-- Admin: Gold Ball Challenge bets, winners & losers (auto-detects Gold Ball table)
create or replace function public.admin_gold_bets(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_gold_tbl text;
  v_rows jsonb;
  v_total_staked bigint := 0;
  v_total_payout bigint := 0;
  v_wins bigint := 0;
  v_losses bigint := 0;
begin
  select * into v_auth from public._p2w_aviator_auth(p_token);
  if v_auth.user_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  select format('%I.%I', t.table_schema, t.table_name)
  into v_gold_tbl
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in ('aviator_rounds','aviator_global_rounds','aviator_bets','referral_settings','user_referrals','referral_events','email_auth_accounts')
  group by t.table_schema, t.table_name
  having bool_or(c.column_name = 'user_id')
     and (
       t.table_name ilike '%gold%'
       or bool_or(c.column_name in ('winning_cup','chosen_cup','picked_cup','total_entry'))
     )
  order by (t.table_schema = 'public') desc, (t.table_name ilike '%gold%') desc, t.table_name
  limit 1;

  if v_gold_tbl is null then
    return jsonb_build_object(
      'found', false,
      'total_staked', 0,
      'total_payout', 0,
      'wins', 0,
      'losses', 0,
      'rows', '[]'::jsonb
    );
  end if;

  execute format($q$
    with parsed as (
      select
        coalesce(nullif(to_jsonb(g)->>'id','')::bigint, 0) as round_id,
        g.user_id::text as user_id,
        coalesce(nullif(to_jsonb(u)->>'display_name',''), nullif(to_jsonb(u)->>'email',''), g.user_id::text) as user_label,
        coalesce(
          nullif(to_jsonb(g)->>'total_entry','')::integer,
          nullif(to_jsonb(g)->>'stake','')::integer,
          nullif(to_jsonb(g)->>'amount','')::integer,
          0
        ) as stake,
        coalesce(nullif(to_jsonb(g)->>'payout','')::integer, 0) as payout,
        coalesce((to_jsonb(g)->>'won')::boolean, false) as won,
        case
          when (to_jsonb(g)->>'won') is not null then true
          when lower(coalesce(to_jsonb(g)->>'status','')) in ('won','lost','settled','finished','completed') then true
          else false
        end as settled,
        to_jsonb(g)->>'created_at' as created_at
      from %s g
      left join %s u on u.id::text = g.user_id::text
      order by coalesce(nullif(to_jsonb(g)->>'id','')::bigint, 0) desc
      limit 50
    )
    select
      coalesce(sum(stake), 0),
      coalesce(sum(payout), 0),
      coalesce(sum(case when settled and won then 1 else 0 end), 0),
      coalesce(sum(case when settled and not won then 1 else 0 end), 0),
      coalesce(jsonb_agg(row_to_json(parsed)), '[]'::jsonb)
    from parsed
  $q$, v_gold_tbl, v_auth.users_table)
  into v_total_staked, v_total_payout, v_wins, v_losses, v_rows;

  return jsonb_build_object(
    'found', true,
    'total_staked', coalesce(v_total_staked, 0),
    'total_payout', coalesce(v_total_payout, 0),
    'wins', coalesce(v_wins, 0),
    'losses', coalesce(v_losses, 0),
    'rows', coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

grant execute on function public.aviator_state(text) to anon, authenticated;
grant execute on function public.aviator_place_bet(text, bigint, integer, numeric) to anon, authenticated;
grant execute on function public.aviator_cashout(text, bigint, numeric) to anon, authenticated;
grant execute on function public.admin_aviator_bets(text) to anon, authenticated;
grant execute on function public.admin_gold_bets(text) to anon, authenticated;

notify pgrst, 'reload schema';
