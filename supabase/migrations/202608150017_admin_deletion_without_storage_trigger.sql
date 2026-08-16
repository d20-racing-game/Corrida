-- O Postgres não permite excluir diretamente de storage.objects.
-- A remoção do registro continua em cascata; arquivos órfãos podem ser
-- limpos separadamente pela Storage API.

drop trigger if exists players_delete_avatar on public.players;
drop function if exists public.delete_player_avatar();

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
