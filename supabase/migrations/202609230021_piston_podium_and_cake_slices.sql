-- Pódio de três posições e fatias de bolo de uso único na Copa Pistão.

create table if not exists public.piston_cake_attacks (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  source_player_id uuid not null references public.players(id) on delete cascade,
  target_player_id uuid not null references public.players(id) on delete cascade,
  damage smallint not null default 5 check (damage = 5),
  created_at timestamptz not null default now(),
  unique(room_id, source_player_id),
  unique(room_id, round, target_player_id),
  check (source_player_id <> target_player_id)
);

alter table public.piston_cake_attacks enable row level security;
create policy "piston cake attacks are public" on public.piston_cake_attacks
for select to anon, authenticated using (true);
alter publication supabase_realtime add table public.piston_cake_attacks;

alter function public.start_race(text) rename to start_race_before_piston_cakes;
revoke all on function public.start_race_before_piston_cakes(text) from public, anon, authenticated;

create or replace function public.start_race(p_room_code text)
returns public.rooms language plpgsql security definer set search_path = '' as $$
declare v_room public.rooms;
begin
  v_room := public.start_race_before_piston_cakes(p_room_code);
  delete from public.piston_cake_attacks where room_id = v_room.id;
  if v_room.game_mode = 'piston_cup' then
    update public.rooms set piston_countdown_ends_at = now() + interval '8 seconds',
      piston_next_round_at = now() + interval '8 seconds'
    where id = v_room.id returning * into v_room;
  end if;
  return v_room;
end;
$$;
revoke all on function public.start_race(text) from public, anon;
grant execute on function public.start_race(text) to authenticated;

create or replace function public.use_piston_cake(
  p_room_code text, p_source_player_id uuid, p_target_player_id uuid
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_room public.rooms; v_source public.players; v_target public.players; v_attack public.piston_cake_attacks;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null or v_room.status <> 'racing' or v_room.game_mode <> 'piston_cup' then
    raise exception 'A Copa Pistão não está ativa';
  end if;
  if now() < coalesce(v_room.piston_next_round_at, now()) then raise exception 'Aguarde a rodada começar'; end if;
  select * into v_source from public.players where id = p_source_player_id and room_id = v_room.id for update;
  select * into v_target from public.players where id = p_target_player_id and room_id = v_room.id for update;
  if v_source.id is null or v_source.owner_id <> auth.uid() then raise exception 'Este corredor não é seu'; end if;
  if v_source.score <= 20 then raise exception 'O corredor precisa passar de 20 pontos'; end if;
  if v_source.finish_position is not null or v_source.is_spectator or v_source.spectator_only then raise exception 'Corredor inválido'; end if;
  if v_target.id is null or v_target.id = v_source.id or v_target.finish_position is not null
    or v_target.is_spectator or v_target.spectator_only then raise exception 'Alvo inválido'; end if;
  if exists (select 1 from public.piston_round_rolls where room_id = v_room.id
    and round = v_room.piston_round and player_id = v_source.id) then
    raise exception 'O bolo deve ser usado antes de rolar o dado';
  end if;

  insert into public.piston_cake_attacks(room_id, round, source_player_id, target_player_id)
  values(v_room.id, v_room.piston_round, v_source.id, v_target.id) returning * into v_attack;
  update public.players set score = greatest(0, score - 5) where id = v_target.id;
  return jsonb_build_object('id', v_attack.id, 'source_player_id', v_source.id,
    'target_player_id', v_target.id, 'round', v_room.piston_round, 'damage', 5);
exception
  when unique_violation then
    if exists (select 1 from public.piston_cake_attacks where room_id = v_room.id and source_player_id = v_source.id) then
      raise exception 'Esta fatia de bolo já foi usada';
    end if;
    raise exception 'Este corredor já recebeu um bolo nesta rodada';
end;
$$;
revoke all on function public.use_piston_cake(text, uuid, uuid) from public, anon;
grant execute on function public.use_piston_cake(text, uuid, uuid) to authenticated;

create or replace function public.roll_piston_d20(p_room_code text, p_player_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms; v_player public.players;
  v_roll integer := floor(random() * 20 + 1); v_boost integer := 0; v_total integer;
  v_lap integer; v_marker integer; v_all_rolled boolean; v_event jsonb; v_results jsonb;
  v_total_distance integer; v_finish_limit integer; v_open_podium integer;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null or v_room.status <> 'racing' or v_room.game_mode <> 'piston_cup' then raise exception 'A Copa Pistão não está ativa nesta sala'; end if;
  if now() < greatest(v_room.piston_countdown_ends_at, v_room.piston_next_round_at) then raise exception 'Aguarde a largada da rodada'; end if;
  select * into v_player from public.players where id = p_player_id and room_id = v_room.id
    and is_spectator = false and spectator_only = false and finish_position is null for update;
  if v_player.id is null then raise exception 'Corredor inválido'; end if;
  if v_player.owner_id <> auth.uid() then raise exception 'Este corredor não é seu'; end if;

  select route.lap, route.marker into v_lap, v_marker from (
    select lap_number::integer lap, marker_value::integer marker,
      ((lap_number - 1) * 100 + marker_value)::integer absolute
    from generate_series(1, v_room.laps) laps(lap_number)
    cross join unnest(array[25, 50, 75]) markers(marker_value)
  ) route where route.absolute > v_player.score and route.absolute <= v_player.score + v_roll
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
  into v_all_rolled from public.piston_round_rolls where room_id = v_room.id and round = v_room.piston_round;

  if v_all_rolled then
    v_total_distance := v_room.laps * 100;
    v_finish_limit := least(3, (select count(*) from public.players where room_id = v_room.id and is_spectator = false and spectator_only = false));
    v_open_podium := greatest(0, v_finish_limit - (select count(*) from public.players where room_id = v_room.id and finish_position is not null));
    update public.players player set score = least(v_total_distance, player.score + rolls.total), roll_count = player.roll_count + 1
    from public.piston_round_rolls rolls where rolls.room_id = v_room.id and rolls.round = v_room.piston_round and rolls.player_id = player.id;

    with ranked as (
      select player.id, row_number() over(order by rolls.total desc, rolls.created_at, player.id) offset
      from public.players player join public.piston_round_rolls rolls on rolls.player_id = player.id
      where rolls.room_id = v_room.id and rolls.round = v_room.piston_round
        and player.score >= v_total_distance and player.finish_position is null
    ), finishers as (select * from ranked where offset <= v_open_podium),
    base as (select count(*) amount from public.players where room_id = v_room.id and finish_position is not null)
    update public.players player set finish_position = base.amount + finishers.offset, finished_at = now()
    from finishers, base where player.id = finishers.id;

    select jsonb_agg(jsonb_build_object('player_id', rolls.player_id, 'roll', rolls.roll,
      'boost', rolls.boost, 'total', rolls.total, 'lightning_marker', rolls.lightning_marker,
      'finish_position', player.finish_position)) into v_results
    from public.piston_round_rolls rolls join public.players player on player.id = rolls.player_id
    where rolls.room_id = v_room.id and rolls.round = v_room.piston_round;
    v_event := jsonb_build_object('id', gen_random_uuid(), 'type', 'piston_round',
      'round', v_room.piston_round, 'results', v_results, 'created_at', now());

    if (select count(*) from public.players where room_id = v_room.id and finish_position is not null) >= v_finish_limit then
      update public.rooms set status = 'finished', last_event = v_event,
        winner_id = (select id from public.players where room_id = v_room.id and finish_position = 1), piston_next_round_at = null where id = v_room.id;
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
