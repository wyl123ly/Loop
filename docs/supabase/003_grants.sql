-- Supabase 2026 Data API grants for Loop snapshot tables.
-- Run in SQL Editor after 001_core.sql.
-- RLS still applies; grants only make tables visible to the authenticated role.

grant usage on schema public to authenticated;

grant select, insert, update, delete
  on table public.profiles,
           public.devices,
           public.snapshots,
           public.sync_state
  to authenticated;

-- Future tables created by migrations in this project.
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

notify pgrst, 'reload schema';
