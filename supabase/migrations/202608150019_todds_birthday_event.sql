-- Evento temporário de aniversário: ativo por 24 horas após o deploy.

create table if not exists public.temporary_events (
  id text primary key,
  starts_at timestamptz not null,
  ends_at timestamptz not null
);

alter table public.temporary_events enable row level security;
drop policy if exists "temporary events are public" on public.temporary_events;
create policy "temporary events are public" on public.temporary_events
for select to anon, authenticated using (true);

insert into public.temporary_events(id, starts_at, ends_at)
values ('todds-birthday', now(), now() + interval '24 hours')
on conflict (id) do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at;

create table if not exists public.birthday_cake_claims (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  marker smallint not null check (marker in (12, 32, 62, 82)),
  effect text not null check (effect in ('extra_roll', 'spiked')),
  claimed_at timestamptz not null default now(),
  unique(room_id, marker)
);

alter table public.birthday_cake_claims enable row level security;
drop policy if exists "birthday cake claims are public" on public.birthday_cake_claims;
create policy "birthday cake claims are public" on public.birthday_cake_claims
for select to anon, authenticated using (true);

alter table public.rooms add column if not exists birthday_bonus_player_id uuid
references public.players(id) on delete set null;

create or replace function public.reset_birthday_cakes_on_race_start()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'racing' and old.status is distinct from new.status then
    delete from public.birthday_cake_claims where room_id = new.id;
    new.birthday_bonus_player_id = null;
  end if;
  return new;
end;
$$;

drop trigger if exists rooms_reset_birthday_cakes on public.rooms;
create trigger rooms_reset_birthday_cakes
before update of status on public.rooms
for each row execute function public.reset_birthday_cakes_on_race_start();

alter function public.roll_d20_core_positions(text) rename to roll_d20_core_before_birthday;
revoke all on function public.roll_d20_core_before_birthday(text) from public, anon, authenticated;

create or replace function public.roll_d20_core_positions(p_room_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_player public.players;
  v_old_score integer;
  v_new_score integer;
  v_marker integer;
  v_effect text;
  v_event jsonb;
  v_result jsonb;
  v_active boolean;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  select * into v_player from public.players where id = v_room.current_player_id for update;
  v_old_score := v_player.score;

  -- A rolagem extra anterior foi usada agora.
  if v_room.birthday_bonus_player_id = v_player.id then
    update public.rooms set birthday_bonus_player_id = null where id = v_room.id;
  end if;

  v_result := public.roll_d20_core_before_birthday(p_room_code);
  v_new_score := coalesce((v_result->>'score')::integer, v_old_score);

  select exists (
    select 1 from public.temporary_events
    where id = 'todds-birthday' and now() >= starts_at and now() < ends_at
  ) into v_active;

  if v_active then
    select cake.marker_value into v_marker
    from unnest(array[12, 32, 62, 82]) as cake(marker_value)
    where cake.marker_value > v_old_score and cake.marker_value <= v_new_score
      and not exists (
        select 1 from public.birthday_cake_claims claim
        where claim.room_id = v_room.id and claim.marker = cake.marker_value
      )
    order by cake.marker_value limit 1;
  end if;

  if v_marker is not null then
    v_effect := case when random() < .5 then 'extra_roll' else 'spiked' end;
    insert into public.birthday_cake_claims(room_id, player_id, marker, effect)
    values(v_room.id, v_player.id, v_marker, v_effect);

    if v_effect = 'spiked' then
      v_new_score := greatest(0, v_new_score - 3);
      update public.players set score = v_new_score where id = v_player.id;
    else
      update public.rooms set birthday_bonus_player_id = v_player.id,
        current_player_id = v_player.id, turn_started_at = now()
      where id = v_room.id;
    end if;

    v_event := jsonb_build_object(
      'id', gen_random_uuid(), 'type', 'birthday_cake',
      'source_id', v_player.id, 'marker', v_marker,
      'effect', v_effect, 'created_at', now()
    );
    update public.rooms set last_event = v_event where id = v_room.id;
    v_result := v_result || jsonb_build_object(
      'birthday_event', v_event, 'event', v_event, 'score', v_new_score
    );
  end if;

  return v_result;
end;
$$;

revoke all on function public.roll_d20_core_positions(text) from public, anon, authenticated;

-- Preserva a rolagem extra quando também houver um presente comum pendente.
alter function public.use_pending_item(text, uuid) rename to use_pending_item_before_birthday;
revoke all on function public.use_pending_item_before_birthday(text, uuid) from public, anon, authenticated;

create or replace function public.use_pending_item(p_room_code text, p_target_player_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_result jsonb; v_bonus uuid;
begin
  select birthday_bonus_player_id into v_bonus from public.rooms where code = upper(p_room_code);
  v_result := public.use_pending_item_before_birthday(p_room_code, p_target_player_id);
  if v_bonus is not null then
    update public.rooms set current_player_id = v_bonus, turn_started_at = now()
    where code = upper(p_room_code);
  end if;
  return v_result;
end;
$$;
revoke all on function public.use_pending_item(text, uuid) from public, anon;
grant execute on function public.use_pending_item(text, uuid) to authenticated;

alter function public.expire_pending_item(text) rename to expire_pending_item_before_birthday;
revoke all on function public.expire_pending_item_before_birthday(text) from public, anon, authenticated;

create or replace function public.expire_pending_item(p_room_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_result boolean; v_bonus uuid;
begin
  select birthday_bonus_player_id into v_bonus from public.rooms where code = upper(p_room_code);
  v_result := public.expire_pending_item_before_birthday(p_room_code);
  if v_result and v_bonus is not null then
    update public.rooms set current_player_id = v_bonus, turn_started_at = now()
    where code = upper(p_room_code);
  end if;
  return v_result;
end;
$$;
revoke all on function public.expire_pending_item(text) from public, anon;
grant execute on function public.expire_pending_item(text) to authenticated;
