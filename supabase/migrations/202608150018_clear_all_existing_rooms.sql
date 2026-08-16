-- Limpeza única solicitada: remove todas as salas existentes e seus dados
-- dependentes. Novas salas criadas depois desta migração não são afetadas.

update public.rooms
set current_player_id = null,
    winner_id = null,
    pending_item = null;

delete from public.rooms;
