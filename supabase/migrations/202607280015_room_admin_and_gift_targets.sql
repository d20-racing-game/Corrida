-- Administração permanente do anfitrião e exclusão confiável da sala.

drop policy if exists "player owner or room owner can delete player" on public.players;
create policy "player owner or room owner can delete player"
on public.players for delete to authenticated using (
  (select auth.uid()) = owner_id
  or exists (
    select 1 from public.rooms room
    where room.id = players.room_id
      and room.owner_id = (select auth.uid())
  )
);

create or replace function public.delete_room(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_room_id uuid;
begin
  select id into v_room_id
  from public.rooms
  where code = upper(p_room_code)
    and owner_id = auth.uid()
  for update;

  if v_room_id is null then
    raise exception 'Somente o dono pode excluir a sala';
  end if;

  update public.rooms
  set current_player_id = null,
      winner_id = null,
      pending_item = null
  where id = v_room_id;

  delete from public.rooms where id = v_room_id;
  return true;
end;
$$;

revoke all on function public.delete_room(text) from public, anon;
grant execute on function public.delete_room(text) to authenticated;
