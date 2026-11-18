-- Play2Win Ludo Multiplayer + Bot Fallback + 15% Platform Fees + Lives Sync (Supabase SQL Migration)
-- Run this script once in your Supabase Dashboard -> SQL Editor.
-- Features:
--   * Supports 2 Player, 3 Player & 4 Player Ludo rooms
--   * Bet tabs: 5, 10, 25, 50, 100, 200, 500 Coins
--   * 10-second live player matchmaking window; fills empty seats with randomly named opponents if no opponent joins
--   * Total pool = player_count * bet_amount; Winner receives 85% of total pool (15% platform fee cut)
--   * Stores every settled match's 15% platform fee in public.ludo_platform_fees for date-range Admin reporting
--   * Admin Live Ludo & Date-Range Fee overview RPC: admin_ludo_bets(p_token, p_from_date, p_to_date)

create table if not exists public.ludo_matches (
  id bigserial primary key,
  player_count integer not null check (player_count in (2, 3, 4)),
  bet_amount integer not null check (bet_amount in (5, 10, 25, 50, 100, 200, 500)),
  total_pool integer not null check (total_pool > 0),
  platform_cut integer not null check (platform_cut >= 0),
  winner_payout integer not null check (winner_payout > 0),
  status text not null default 'searching' check (status in ('searching', 'playing', 'completed', 'cancelled')),
  search_ends_at timestamptz not null,
  players_json jsonb not null default '[]'::jsonb,
  state_json jsonb,
  turn_seq integer not null default 0,
  winner_seat integer,
  winner_user_id text,
  winner_name text,
  created_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  finished_at timestamptz
);

create table if not exists public.ludo_match_players (
  id bigserial primary key,
  match_id bigint not null references public.ludo_matches(id) on delete cascade,
  seat integer not null check (seat between 0 and 3),
  user_id text not null,
  player_name text not null,
  bet_amount integer not null,
  payout integer not null default 0,
  status text not null default 'joined' check (status in ('joined', 'won', 'lost', 'refunded')),
  created_at timestamptz not null default clock_timestamp(),
  settled_at timestamptz,
  unique (match_id, user_id)
);

-- Dedicated ledger table for 15% platform fees so Admin can inspect fee earnings by date range
create table if not exists public.ludo_platform_fees (
  id bigserial primary key,
  match_id bigint not null unique references public.ludo_matches(id) on delete cascade,
  player_count integer not null,
  bet_amount integer not null,
  total_pool integer not null,
  winner_payout integer not null,
  fee_amount integer not null,
  fee_percent numeric(5,2) not null default 15.00,
  winner_name text,
  winner_is_bot boolean not null default false,
  fee_date date not null default (clock_timestamp() at time zone 'Asia/Kolkata')::date,
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists idx_ludo_matches_search on public.ludo_matches (status, player_count, bet_amount, search_ends_at);
create index if not exists idx_ludo_matches_created on public.ludo_matches (id desc);
create index if not exists idx_ludo_match_players_user on public.ludo_match_players (user_id, id desc);
create index if not exists idx_ludo_platform_fees_date on public.ludo_platform_fees (fee_date desc, id desc);

create or replace function public._p2w_ludo_detect_schema()
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
    and t.table_name not in (
      'referral_settings','user_referrals','referral_events','email_auth_accounts',
      'aviator_rounds','aviator_global_rounds','aviator_bets',
      'number_game_admin_overrides','withdrawal_rejection_reasons',
      'ludo_matches','ludo_match_players','ludo_platform_fees',
      'rummy_matches','rummy_match_players','rummy_platform_fees'
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

  select format('%I.%I', t.table_schema, t.table_name)
  into v_coin_log_tbl
  from information_schema.tables t
  join information_schema.columns c
    on c.table_schema = t.table_schema and c.table_name = t.table_name
  where t.table_type = 'BASE TABLE'
    and t.table_schema not in ('pg_catalog','information_schema','auth','storage','realtime','supabase_functions','vault','extensions')
    and t.table_name not in (
      'referral_settings','user_referrals','referral_events','email_auth_accounts',
      'aviator_rounds','aviator_global_rounds','aviator_bets',
      'number_game_admin_overrides','withdrawal_rejection_reasons',
      'ludo_matches','ludo_match_players','ludo_platform_fees'
    )
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

create or replace function public._p2w_ludo_auth(p_token text)
returns table(user_id text, user_role text, user_name text, balance bigint, users_table text, balance_col text, coin_log_table text)
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
  v_name text;
  v_bal bigint;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Session expired. Please log in again.';
  end if;

  select * into v_schema from public._p2w_ludo_detect_schema();
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
    'select
       coalesce(nullif(to_jsonb(u)->>''role'',''''), case when coalesce((to_jsonb(u)->>''is_admin'')::boolean, false) then ''admin'' else ''user'' end),
       coalesce(
         nullif(trim(to_jsonb(u)->>''display_name''), ''''),
         nullif(split_part(coalesce(to_jsonb(u)->>''email'',''''), ''@'', 1), ''''),
         u.id::text
       ),
       coalesce(%I, 0)::bigint
     from %s u where u.id::text = $1 limit 1',
    v_schema.balance_col,
    v_schema.users_table
  ) into v_role, v_name, v_bal using v_uid;

  if v_role is null then
    raise exception 'Account not found.';
  end if;

  return query select v_uid, v_role, coalesce(v_name, v_uid), coalesce(v_bal, 0), v_schema.users_table, v_schema.balance_col, v_schema.coin_log_table;
end;
$$;

create or replace function public._p2w_ludo_log_coin(
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

create or replace function public._p2w_ludo_seat_color(p_player_count integer, p_seat integer)
returns text
language plpgsql
immutable
as $$
begin
  if p_player_count = 2 then
    return case p_seat when 0 then 'blue' else 'green' end;
  elsif p_player_count = 3 then
    return case p_seat when 0 then 'blue' when 1 then 'red' else 'green' end;
  else
    return case p_seat when 0 then 'blue' when 1 then 'red' when 2 then 'green' else 'yellow' end;
  end if;
end;
$$;

create or replace function public._p2w_ludo_initial_state(p_player_count integer)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_tokens jsonb := '[]'::jsonb;
  v_lives jsonb := '[]'::jsonb;
  v_elim jsonb := '[]'::jsonb;
  i integer;
begin
  for i in 0..(p_player_count - 1) loop
    v_tokens := v_tokens || jsonb_build_array('[-1,-1,-1,-1]'::jsonb);
    v_lives := v_lives || jsonb_build_array(3);
    v_elim := v_elim || jsonb_build_array(false);
  end loop;
  return jsonb_build_object(
    'tokens', v_tokens,
    'lives', v_lives,
    'eliminated', v_elim,
    'turn', 0,
    'seq', 0,
    'consecSix', 0,
    'lastRoll', null,
    'winnerSeat', null
  );
end;
$$;

create or replace function public._p2w_ludo_serialize_match(
  p_match public.ludo_matches,
  p_balance bigint
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_left_ms bigint;
begin
  v_left_ms := greatest(0, round(extract(epoch from (p_match.search_ends_at - v_now)) * 1000))::bigint;
  return jsonb_build_object(
    'id', p_match.id,
    'player_count', p_match.player_count,
    'bet_amount', p_match.bet_amount,
    'total_pool', p_match.total_pool,
    'platform_cut', p_match.platform_cut,
    'winner_payout', p_match.winner_payout,
    'status', p_match.status,
    'search_ends_at', p_match.search_ends_at,
    'search_left_ms', v_left_ms,
    'players', coalesce(p_match.players_json, '[]'::jsonb),
    'state_json', p_match.state_json,
    'turn_seq', p_match.turn_seq,
    'winner_seat', p_match.winner_seat,
    'winner_user_id', p_match.winner_user_id,
    'winner_name', p_match.winner_name,
    'balance', coalesce(p_balance, 0)
  );
end;
$$;

-- Join or create a Ludo matchmaking room (10-second opponent search window, 15% platform cut)
create or replace function public.ludo_matchmake(
  p_token text,
  p_player_count integer,
  p_bet_amount integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_now timestamptz := clock_timestamp();
  v_match public.ludo_matches;
  v_seat integer;
  v_color text;
  v_new_balance bigint;
  v_pool integer;
  v_payout integer;
  v_cut integer;
  v_players jsonb;
  v_new_player jsonb;
  v_clean_name text;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);
  if v_auth.user_role = 'admin' then
    raise exception 'Admin accounts cannot play Ludo.';
  end if;

  if p_player_count not in (2, 3, 4) then
    raise exception 'Player count 2, 3 ya 4 hona chahiye.';
  end if;
  if p_bet_amount not in (5, 10, 25, 50, 100, 200, 500) then
    raise exception 'Valid bet amount (5, 10, 25, 50, 100, 200, 500 Coins) chunein.';
  end if;

  perform pg_advisory_xact_lock(92847221);

  -- Deduct entry fee first cleanly
  execute format(
    'update %s set %I = coalesce(%I, 0) - $1 where id::text = $2 and coalesce(%I, 0) >= $1 returning %I::bigint',
    v_auth.users_table, v_auth.balance_col, v_auth.balance_col, v_auth.balance_col, v_auth.balance_col
  ) into v_new_balance using p_bet_amount, v_auth.user_id;

  if v_new_balance is null then
    raise exception 'Insufficient coins balance. Kam se kam % Coins chahiye.', p_bet_amount;
  end if;

  v_clean_name := coalesce(nullif(trim(v_auth.user_name), ''), 'Player');
  if length(v_clean_name) > 18 then
    v_clean_name := left(v_clean_name, 18);
  end if;

  -- Try to join an open live searching room for the same player_count & bet_amount
  select m.* into v_match
  from public.ludo_matches m
  where m.status = 'searching'
    and m.player_count = p_player_count
    and m.bet_amount = p_bet_amount
    and m.search_ends_at > (v_now + interval '0.8 seconds')
    and jsonb_array_length(m.players_json) < m.player_count
    and not exists (
      select 1 from public.ludo_match_players p
      where p.match_id = m.id and p.user_id = v_auth.user_id
    )
  order by m.id asc
  limit 1
  for update;

  if found then
    v_seat := jsonb_array_length(v_match.players_json);
    v_color := public._p2w_ludo_seat_color(p_player_count, v_seat);
    v_new_player := jsonb_build_object(
      'seat', v_seat,
      'user_id', v_auth.user_id,
      'name', v_clean_name,
      'is_bot', false,
      'color', v_color
    );
    v_players := v_match.players_json || jsonb_build_array(v_new_player);

    insert into public.ludo_match_players (match_id, seat, user_id, player_name, bet_amount, status)
    values (v_match.id, v_seat, v_auth.user_id, v_clean_name, p_bet_amount, 'joined');

    if jsonb_array_length(v_players) >= v_match.player_count then
      update public.ludo_matches
      set players_json = v_players,
          status = 'playing',
          started_at = v_now,
          state_json = coalesce(state_json, public._p2w_ludo_initial_state(v_match.player_count))
      where id = v_match.id
      returning * into v_match;
    else
      update public.ludo_matches
      set players_json = v_players
      where id = v_match.id
      returning * into v_match;
    end if;
  else
    v_pool := p_player_count * p_bet_amount;
    v_payout := greatest(1, floor(v_pool * 0.85)::integer);
    v_cut := greatest(0, v_pool - v_payout);
    v_color := public._p2w_ludo_seat_color(p_player_count, 0);
    v_players := jsonb_build_array(
      jsonb_build_object(
        'seat', 0,
        'user_id', v_auth.user_id,
        'name', v_clean_name,
        'is_bot', false,
        'color', v_color
      )
    );

    insert into public.ludo_matches (
      player_count, bet_amount, total_pool, platform_cut, winner_payout,
      status, search_ends_at, players_json, state_json
    )
    values (
      p_player_count, p_bet_amount, v_pool, v_cut, v_payout,
      'searching', v_now + interval '10 seconds', v_players, public._p2w_ludo_initial_state(p_player_count)
    )
    returning * into v_match;

    insert into public.ludo_match_players (match_id, seat, user_id, player_name, bet_amount, status)
    values (v_match.id, 0, v_auth.user_id, v_clean_name, p_bet_amount, 'joined');
  end if;

  perform public._p2w_ludo_log_coin(
    v_auth.coin_log_table,
    v_auth.user_id,
    -p_bet_amount,
    format('Ludo %sP entry (Match #%s)', p_player_count, v_match.id)
  );

  return public._p2w_ludo_serialize_match(v_match, v_new_balance);
end;
$$;

create or replace function public.ludo_match_status(
  p_token text,
  p_match_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_match public.ludo_matches;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);

  select * into v_match from public.ludo_matches where id = p_match_id;
  if not found then
    raise exception 'Ludo match not found.';
  end if;

  return public._p2w_ludo_serialize_match(v_match, v_auth.balance);
end;
$$;

-- Fill remaining seats with randomly named opponents after 10s search (never labelled "Bot")
create or replace function public.ludo_start_with_bots(
  p_token text,
  p_match_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_match public.ludo_matches;
  v_players jsonb;
  v_idx integer;
  v_color text;
  v_names text[] := array[
    'Aarav', 'Rohan', 'Kabir', 'Vikram', 'Neha', 'Priya', 'Ananya', 'Karan',
    'Sahil', 'Devansh', 'Aditya', 'Meera', 'Rahul', 'Simran', 'Aman', 'Nikhil',
    'Pooja', 'Arjun', 'Deepak', 'Tanya', 'Saurabh', 'Riya', 'Manish', 'Komal',
    'Yash', 'Sneha', 'Gaurav', 'Nisha', 'Harsh', 'Kunal', 'Vikas', 'Payal'
  ];
  v_used_names text[];
  v_pick text;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);
  perform pg_advisory_xact_lock(92847222 + coalesce(p_match_id, 0));

  select * into v_match from public.ludo_matches where id = p_match_id for update;
  if not found then
    raise exception 'Ludo match not found.';
  end if;

  if not exists (
    select 1 from public.ludo_match_players
    where match_id = v_match.id and user_id = v_auth.user_id and status <> 'refunded'
  ) then
    raise exception 'Aap is Ludo match mein shamil nahi hain.';
  end if;

  if v_match.status <> 'searching' then
    return public._p2w_ludo_serialize_match(v_match, v_auth.balance);
  end if;

  v_players := coalesce(v_match.players_json, '[]'::jsonb);

  select array_agg(lower(coalesce(el->>'name', '')))
  into v_used_names
  from jsonb_array_elements(v_players) el;
  v_used_names := coalesce(v_used_names, array[]::text[]);

  while jsonb_array_length(v_players) < v_match.player_count loop
    v_idx := jsonb_array_length(v_players);
    v_color := public._p2w_ludo_seat_color(v_match.player_count, v_idx);

    select n into v_pick
    from unnest(v_names) as n
    where not (lower(n) = any(v_used_names))
    order by random()
    limit 1;

    if v_pick is null then
      v_pick := 'Player ' || (10 + floor(random() * 89)::integer)::text;
    end if;

    v_used_names := array_append(v_used_names, lower(v_pick));
    v_players := v_players || jsonb_build_array(
      jsonb_build_object(
        'seat', v_idx,
        'user_id', 'opp_' || v_match.id::text || '_' || v_idx::text,
        'name', v_pick,
        'is_bot', true,
        'color', v_color
      )
    );
  end loop;

  update public.ludo_matches
  set players_json = v_players,
      status = 'playing',
      started_at = clock_timestamp(),
      state_json = coalesce(state_json, public._p2w_ludo_initial_state(v_match.player_count))
  where id = v_match.id
  returning * into v_match;

  return public._p2w_ludo_serialize_match(v_match, v_auth.balance);
end;
$$;

-- Cancel search and refund coins if match hasn't started yet
create or replace function public.ludo_cancel_search(
  p_token text,
  p_match_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_match public.ludo_matches;
  v_player public.ludo_match_players;
  v_new_balance bigint;
  v_remaining jsonb;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);
  perform pg_advisory_xact_lock(92847222 + coalesce(p_match_id, 0));

  select * into v_match from public.ludo_matches where id = p_match_id for update;
  if not found then
    raise exception 'Ludo match not found.';
  end if;

  if v_match.status <> 'searching' then
    raise exception 'Match shuru ho chuka hai, ab cancel nahi ho sakta.';
  end if;

  select * into v_player
  from public.ludo_match_players
  where match_id = v_match.id and user_id = v_auth.user_id and status = 'joined'
  for update;

  if not found then
    return jsonb_build_object('ok', true, 'balance', v_auth.balance);
  end if;

  update public.ludo_match_players
  set status = 'refunded',
      settled_at = clock_timestamp()
  where id = v_player.id;

  execute format(
    'update %s set %I = coalesce(%I, 0) + $1 where id::text = $2 returning %I::bigint',
    v_auth.users_table, v_auth.balance_col, v_auth.balance_col, v_auth.balance_col
  ) into v_new_balance using v_player.bet_amount, v_auth.user_id;

  perform public._p2w_ludo_log_coin(
    v_auth.coin_log_table,
    v_auth.user_id,
    v_player.bet_amount,
    format('Ludo search cancelled refund (Match #%s)', v_match.id)
  );

  select coalesce(jsonb_agg(el), '[]'::jsonb)
  into v_remaining
  from jsonb_array_elements(coalesce(v_match.players_json, '[]'::jsonb)) el
  where el->>'user_id' <> v_auth.user_id;

  if jsonb_array_length(v_remaining) = 0 then
    update public.ludo_matches
    set players_json = '[]'::jsonb,
        status = 'cancelled',
        finished_at = clock_timestamp()
    where id = v_match.id;
  else
    update public.ludo_matches
    set players_json = v_remaining
    where id = v_match.id;
  end if;

  return jsonb_build_object('ok', true, 'balance', coalesce(v_new_balance, v_auth.balance));
end;
$$;

-- Sync real-time turns across human opponents when multiple players matched
create or replace function public.ludo_push_state(
  p_token text,
  p_match_id bigint,
  p_expected_seq integer,
  p_state_json jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_match public.ludo_matches;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);
  perform pg_advisory_xact_lock(92847222 + coalesce(p_match_id, 0));

  select * into v_match from public.ludo_matches where id = p_match_id for update;
  if not found then
    raise exception 'Ludo match not found.';
  end if;

  if not exists (
    select 1 from public.ludo_match_players
    where match_id = v_match.id and user_id = v_auth.user_id and status <> 'refunded'
  ) then
    raise exception 'Access denied.';
  end if;

  if v_match.status = 'playing' and (p_expected_seq is null or v_match.turn_seq <= p_expected_seq) then
    update public.ludo_matches
    set state_json = p_state_json,
        turn_seq = v_match.turn_seq + 1
    where id = v_match.id
    returning * into v_match;
  end if;

  return public._p2w_ludo_serialize_match(v_match, v_auth.balance);
end;
$$;

-- Settle match winner, award 85% of total pool, & log 15% platform fee into ludo_platform_fees
create or replace function public.ludo_finish_match(
  p_token text,
  p_match_id bigint,
  p_winner_seat integer,
  p_winner_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_match public.ludo_matches;
  v_winner_el jsonb;
  v_winner_uid text;
  v_winner_name text;
  v_winner_is_bot boolean := false;
  v_payout integer;
  v_cut integer;
  v_fresh_bal bigint;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);
  perform pg_advisory_xact_lock(92847222 + coalesce(p_match_id, 0));

  select * into v_match from public.ludo_matches where id = p_match_id for update;
  if not found then
    raise exception 'Ludo match not found.';
  end if;

  if not exists (
    select 1 from public.ludo_match_players
    where match_id = v_match.id and user_id = v_auth.user_id and status <> 'refunded'
  ) then
    raise exception 'Access denied.';
  end if;

  if v_match.status = 'completed' then
    execute format('select coalesce(%I, 0)::bigint from %s where id::text = $1', v_auth.balance_col, v_auth.users_table)
      into v_fresh_bal using v_auth.user_id;
    return jsonb_build_object(
      'ok', true,
      'already_settled', true,
      'winner_seat', v_match.winner_seat,
      'winner_user_id', v_match.winner_user_id,
      'winner_name', v_match.winner_name,
      'total_pool', v_match.total_pool,
      'platform_cut', v_match.platform_cut,
      'winner_payout', v_match.winner_payout,
      'did_i_win', v_match.winner_user_id = v_auth.user_id,
      'balance', coalesce(v_fresh_bal, v_auth.balance)
    );
  end if;

  select el into v_winner_el
  from jsonb_array_elements(coalesce(v_match.players_json, '[]'::jsonb)) el
  where (el->>'seat')::integer = p_winner_seat
  limit 1;

  if v_winner_el is not null then
    v_winner_uid := v_winner_el->>'user_id';
    v_winner_name := coalesce(nullif(trim(v_winner_el->>'name'), ''), nullif(trim(p_winner_name), ''), 'Player');
    v_winner_is_bot := coalesce((v_winner_el->>'is_bot')::boolean, false);
  else
    v_winner_uid := 'opp_' || v_match.id::text || '_' || coalesce(p_winner_seat, 0)::text;
    v_winner_name := coalesce(nullif(trim(p_winner_name), ''), 'Player');
    v_winner_is_bot := true;
  end if;

  -- Guarantee 85% winner payout / 15% platform fee even on in-flight matches created pre-migration
  v_payout := greatest(1, floor(v_match.total_pool * 0.85)::integer);
  v_cut := greatest(0, v_match.total_pool - v_payout);

  update public.ludo_matches
  set status = 'completed',
      winner_payout = v_payout,
      platform_cut = v_cut,
      winner_seat = p_winner_seat,
      winner_user_id = v_winner_uid,
      winner_name = v_winner_name,
      finished_at = clock_timestamp()
  where id = v_match.id
  returning * into v_match;

  insert into public.ludo_platform_fees (
    match_id, player_count, bet_amount, total_pool, winner_payout, fee_amount, fee_percent,
    winner_name, winner_is_bot, fee_date
  )
  values (
    v_match.id, v_match.player_count, v_match.bet_amount, v_match.total_pool,
    v_match.winner_payout, v_match.platform_cut, 15.00,
    v_winner_name, v_winner_is_bot, (clock_timestamp() at time zone 'Asia/Kolkata')::date
  )
  on conflict (match_id) do nothing;

  if not v_winner_is_bot and v_winner_uid is not null then
    update public.ludo_match_players
    set status = case when user_id = v_winner_uid then 'won' else 'lost' end,
        payout = case when user_id = v_winner_uid then v_match.winner_payout else 0 end,
        settled_at = clock_timestamp()
    where match_id = v_match.id and status = 'joined';

    execute format(
      'update %s set %I = coalesce(%I, 0) + $1 where id::text = $2',
      v_auth.users_table, v_auth.balance_col, v_auth.balance_col
    ) using v_match.winner_payout, v_winner_uid;

    perform public._p2w_ludo_log_coin(
      v_auth.coin_log_table,
      v_winner_uid,
      v_match.winner_payout,
      format('Ludo %sP win (Match #%s · 85%% of %s pool)', v_match.player_count, v_match.id, v_match.total_pool)
    );
  else
    update public.ludo_match_players
    set status = 'lost',
        payout = 0,
        settled_at = clock_timestamp()
    where match_id = v_match.id and status = 'joined';
  end if;

  execute format('select coalesce(%I, 0)::bigint from %s where id::text = $1', v_auth.balance_col, v_auth.users_table)
    into v_fresh_bal using v_auth.user_id;

  return jsonb_build_object(
    'ok', true,
    'already_settled', false,
    'winner_seat', v_match.winner_seat,
    'winner_user_id', v_match.winner_user_id,
    'winner_name', v_match.winner_name,
    'total_pool', v_match.total_pool,
    'platform_cut', v_match.platform_cut,
    'winner_payout', v_match.winner_payout,
    'did_i_win', v_match.winner_user_id = v_auth.user_id,
    'balance', coalesce(v_fresh_bal, v_auth.balance)
  );
end;
$$;

-- Player match history
create or replace function public.ludo_my_history(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_rows jsonb;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id as match_id,
      m.player_count,
      m.bet_amount,
      m.total_pool,
      m.platform_cut,
      m.winner_payout,
      m.status as match_status,
      m.winner_name,
      mp.status as player_status,
      mp.payout,
      mp.created_at
    from public.ludo_match_players mp
    join public.ludo_matches m on m.id = mp.match_id
    where mp.user_id = v_auth.user_id
    order by mp.id desc
    limit 25
  ) t;

  return jsonb_build_object(
    'balance', v_auth.balance,
    'rows', v_rows
  );
end;
$$;

-- Drop legacy 1-arg signature so PostgREST RPC resolution is unambiguous
drop function if exists public.admin_ludo_bets(text);

-- Admin live & date-range 15% platform fees overview
create or replace function public.admin_ludo_bets(
  p_token text,
  p_from_date date default null,
  p_to_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth record;
  v_total_pool bigint := 0;
  v_total_cut bigint := 0;
  v_total_payout bigint := 0;
  v_total_matches bigint := 0;
  v_daily jsonb;
  v_rows jsonb;
begin
  select * into v_auth from public._p2w_ludo_auth(p_token);
  if v_auth.user_role <> 'admin' then
    raise exception 'Admin access required.';
  end if;

  select
    coalesce(sum(f.total_pool), 0),
    coalesce(sum(f.fee_amount), 0),
    coalesce(sum(f.winner_payout), 0),
    count(*)
  into v_total_pool, v_total_cut, v_total_payout, v_total_matches
  from public.ludo_platform_fees f
  where (p_from_date is null or f.fee_date >= p_from_date)
    and (p_to_date is null or f.fee_date <= p_to_date);

  select coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb)
  into v_daily
  from (
    select
      f.fee_date,
      count(*) as matches_count,
      sum(f.total_pool) as total_pool,
      sum(f.fee_amount) as total_fee,
      sum(f.winner_payout) as total_payout
    from public.ludo_platform_fees f
    where (p_from_date is null or f.fee_date >= p_from_date)
      and (p_to_date is null or f.fee_date <= p_to_date)
    group by f.fee_date
    order by f.fee_date desc
    limit 60
  ) d;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id as match_id,
      m.player_count,
      m.bet_amount,
      m.total_pool,
      coalesce(f.fee_amount, m.platform_cut) as platform_cut,
      m.winner_payout,
      m.status,
      m.winner_name,
      coalesce(f.fee_date, (m.created_at at time zone 'Asia/Kolkata')::date) as fee_date,
      (
        select string_agg(el->>'name', ', ')
        from jsonb_array_elements(coalesce(m.players_json, '[]'::jsonb)) el
      ) as players_summary,
      m.created_at
    from public.ludo_matches m
    left join public.ludo_platform_fees f on f.match_id = m.id
    where (p_from_date is null or coalesce(f.fee_date, (m.created_at at time zone 'Asia/Kolkata')::date) >= p_from_date)
      and (p_to_date is null or coalesce(f.fee_date, (m.created_at at time zone 'Asia/Kolkata')::date) <= p_to_date)
    order by m.id desc
    limit 50
  ) t;

  return jsonb_build_object(
    'total_pool', v_total_pool,
    'total_cut', v_total_cut,
    'total_payout', v_total_payout,
    'total_matches', v_total_matches,
    'daily_fees', v_daily,
    'rows', v_rows
  );
end;
$$;

grant execute on function public.ludo_matchmake(text, integer, integer) to anon, authenticated;
grant execute on function public.ludo_match_status(text, bigint) to anon, authenticated;
grant execute on function public.ludo_start_with_bots(text, bigint) to anon, authenticated;
grant execute on function public.ludo_cancel_search(text, bigint) to anon, authenticated;
grant execute on function public.ludo_push_state(text, bigint, integer, jsonb) to anon, authenticated;
grant execute on function public.ludo_finish_match(text, bigint, integer, text) to anon, authenticated;
grant execute on function public.ludo_my_history(text) to anon, authenticated;
grant execute on function public.admin_ludo_bets(text, date, date) to anon, authenticated;

notify pgrst, 'reload schema';
