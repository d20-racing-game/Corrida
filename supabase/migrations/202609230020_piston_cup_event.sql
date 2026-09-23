-- Copa Pistão: modo temporário de 24 horas com rodadas simultâneas.

insert into public.temporary_events(id, starts_at, ends_at)
values ('piston-cup', now(), now() + interval '24 hours')
on conflict (id) do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at;

alter table public.rooms
  add column if not exists game_mode text not null default 'normal'
    check (game_mode in ('normal', 'piston_cup')),
  add column if not exists piston_round integer not null default 0,
  add column if not exists piston_countdown_ends_at timestamptz,
  add column if not exists piston_next_round_at timestamptz;

create table if not exists public.piston_round_rolls (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  round integer not null,
  roll smallint not null check (roll between 1 and 20),
  boost smallint not null default 0 check (boost in (0, 3, 5, 10)),
  total smallint not null,
  lightning_marker smallint,
  created_at timestamptz not null default now(),
  unique(room_id, player_id, round)
);

create table if not exists public.piston_lightning_claims (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  lap smallint not null,
  marker smallint not null check (marker in (25, 50, 75)),
  boost smallint not null check (boost in (3, 5, 10)),
  unique(player_id, lap, marker)
);

alter table public.piston_round_rolls enable row level security;
alter table public.piston_lightning_claims enable row level security;
create policy "piston rolls are public" on public.piston_round_rolls for select to anon, authenticated using (true);
create policy "piston lightning claims are public" on public.piston_lightning_claims for select to anon, authenticated using (true);

alter function public.start_race(text) rename to start_race_before_piston_cup;
revoke all on function public.start_race_before_piston_cup(text) from public, anon, authenticated;

create or replace function public.start_race(p_room_code text)
returns public.rooms language plpgsql security definer set search_path = '' as $$
declare v_room public.rooms;
begin
  v_room := public.start_race_before_piston_cup(p_room_code);
  delete from public.piston_round_rolls where room_id = v_room.id;
  delete from public.piston_lightning_claims where room_id = v_room.id;
  if v_room.game_mode = 'piston_cup' then
    update public.rooms set current_player_id = null, piston_round = 1,
      piston_countdown_ends_at = now() + interval '6 seconds',
      piston_next_round_at = now() + interval '6 seconds', last_roll = null,
      last_event = jsonb_build_object('id', gen_random_uuid(), 'type', 'piston_start', 'created_at', now())
    where id = v_room.id returning * into v_room;
  end if;
  return v_room;
end;
$$;
revoke all on function public.start_race(text) from public, anon;
grant execute on function public.start_race(text) to authenticated;

create or replace function public.roll_piston_d20(p_room_code text, p_player_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_player public.players;
  v_roll integer := floor(random() * 20 + 1);
  v_boost integer := 0;
  v_total integer;
  v_lap integer;
  v_marker integer;
  v_absolute integer;
  v_all_rolled boolean;
  v_event jsonb;
  v_results jsonb;
  v_total_distance integer;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null or v_room.status <> 'racing' or v_room.game_mode <> 'piston_cup' then
    raise exception 'A Copa Pistão não está ativa nesta sala';
  end if;
  if now() < greatest(v_room.piston_countdown_ends_at, v_room.piston_next_round_at) then
    raise exception 'Aguarde a largada da rodada';
  end if;
  select * into v_player from public.players where id = p_player_id and room_id = v_room.id
    and is_spectator = false and spectator_only = false and finish_position is null for update;
  if v_player.id is null then raise exception 'Corredor inválido'; end if;
  if v_player.owner_id <> auth.uid() then raise exception 'Este corredor não é seu'; end if;

  select route.lap, route.marker, route.absolute into v_lap, v_marker, v_absolute
  from (
    select lap_number::integer lap, marker_value::integer marker,
      ((lap_number - 1) * 100 + marker_value)::integer absolute
    from generate_series(1, v_room.laps) laps(lap_number)
    cross join unnest(array[25, 50, 75]) markers(marker_value)
  ) route
  where route.absolute > v_player.score and route.absolute <= v_player.score + v_roll
    and not exists (select 1 from public.piston_lightning_claims claim
      where claim.player_id = v_player.id and claim.lap = route.lap and claim.marker = route.marker)
  order by route.absolute limit 1;

  if v_marker is not null then
    v_boost := (array[3,5,10])[floor(random()*3+1)::integer];
    insert into public.piston_lightning_claims(room_id, player_id, lap, marker, boost)
    values(v_room.id, v_player.id, v_lap, v_marker, v_boost);
  end if;
  v_total := v_roll + v_boost;
  insert into public.piston_round_rolls(room_id, player_id, round, roll, boost, total, lightning_marker)
  values(v_room.id, v_player.id, v_room.piston_round, v_roll, v_boost, v_total, v_marker);

  select count(*) = (select count(*) from public.players where room_id = v_room.id
    and is_spectator = false and spectator_only = false and finish_position is null)
  into v_all_rolled from public.piston_round_rolls
  where room_id = v_room.id and round = v_room.piston_round;

  if v_all_rolled then
    v_total_distance := v_room.laps * 100;
    update public.players player set
      score = least(v_total_distance, player.score + rolls.total),
      roll_count = player.roll_count + 1
    from public.piston_round_rolls rolls
    where rolls.room_id = v_room.id and rolls.round = v_room.piston_round and rolls.player_id = player.id;

    with finishers as (
      select player.id, row_number() over(order by rolls.total desc, rolls.created_at, player.id) as offset
      from public.players player join public.piston_round_rolls rolls on rolls.player_id = player.id
      where rolls.room_id = v_room.id and rolls.round = v_room.piston_round
        and player.score >= v_total_distance and player.finish_position is null
    ), base as (select count(*) amount from public.players where room_id = v_room.id and finish_position is not null)
    update public.players player set finish_position = base.amount + finishers.offset, finished_at = now()
    from finishers, base where player.id = finishers.id;

    select jsonb_agg(jsonb_build_object('player_id', rolls.player_id, 'roll', rolls.roll,
      'boost', rolls.boost, 'total', rolls.total, 'lightning_marker', rolls.lightning_marker))
    into v_results from public.piston_round_rolls rolls
    where rolls.room_id = v_room.id and rolls.round = v_room.piston_round;
    v_event := jsonb_build_object('id', gen_random_uuid(), 'type', 'piston_round',
      'round', v_room.piston_round, 'results', v_results, 'created_at', now());

    if not exists (select 1 from public.players where room_id = v_room.id and finish_position is null
      and is_spectator = false and spectator_only = false) then
      update public.rooms set status = 'finished', last_event = v_event,
        winner_id = (select id from public.players where room_id = v_room.id and finish_position = 1),
        piston_next_round_at = null where id = v_room.id;
    else
      update public.rooms set piston_round = piston_round + 1, last_event = v_event,
        piston_next_round_at = now() + interval '7 seconds' where id = v_room.id;
    end if;
  end if;
  return jsonb_build_object('roll', v_roll, 'boost', v_boost, 'total', v_total,
    'all_rolled', v_all_rolled, 'round', v_room.piston_round);
end;
$$;
revoke all on function public.roll_piston_d20(text, uuid) from public, anon;
grant execute on function public.roll_piston_d20(text, uuid) to authenticated;

alter publication supabase_realtime add table public.piston_round_rolls;
