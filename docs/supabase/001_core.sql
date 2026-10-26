-- Loop 云端快照同步：Supabase 初始化
-- 在 Supabase Dashboard -> SQL Editor 中整段执行。
-- 只使用 auth.users / auth.uid() / storage，不需要 service_role key。
-- 重复执行是安全的：表用 IF NOT EXISTS，策略先 DROP 再 CREATE。

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- profiles
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text default '',
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "loop_profiles_select_own" on public.profiles;
create policy "loop_profiles_select_own"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

drop policy if exists "loop_profiles_update_own" on public.profiles;
create policy "loop_profiles_update_own"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- 新用户注册时自动建 profile；已有用户也可以手动补。
create or replace function public.loop_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.email, ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists loop_on_auth_user_created on auth.users;
create trigger loop_on_auth_user_created
  after insert on auth.users
  for each row execute function public.loop_handle_new_user();

insert into public.profiles (id, display_name)
select id, coalesce(email, '') from auth.users
on conflict (id) do nothing;

-- ---------------------------------------------------------------- devices
create table if not exists public.devices (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null default 'Windows PC',
  platform text not null default 'windows',
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists loop_devices_user_idx on public.devices(user_id);
alter table public.devices enable row level security;

drop policy if exists "loop_devices_select_own" on public.devices;
create policy "loop_devices_select_own"
  on public.devices for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "loop_devices_insert_own" on public.devices;
create policy "loop_devices_insert_own"
  on public.devices for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "loop_devices_update_own" on public.devices;
create policy "loop_devices_update_own"
  on public.devices for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "loop_devices_delete_own" on public.devices;
create policy "loop_devices_delete_own"
  on public.devices for delete
  to authenticated
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------- snapshots
create table if not exists public.snapshots (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  created_at timestamptz not null default now(),
  app_version text not null default '',
  schema_version integer not null default 0,
  total_bytes bigint not null default 0,
  chunk_size integer not null default 16777216,
  chunk_count integer not null default 0,
  sha256 text not null default '',
  manifest jsonb not null default '{}'::jsonb,
  storage_prefix text not null default '',
  status text not null default 'uploading'
    check (status in ('uploading', 'ready', 'failed'))
);

create index if not exists loop_snapshots_user_created_idx
  on public.snapshots(user_id, created_at desc);
create index if not exists loop_snapshots_status_idx
  on public.snapshots(user_id, status);

alter table public.snapshots enable row level security;

drop policy if exists "loop_snapshots_select_own" on public.snapshots;
create policy "loop_snapshots_select_own"
  on public.snapshots for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "loop_snapshots_insert_own" on public.snapshots;
create policy "loop_snapshots_insert_own"
  on public.snapshots for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "loop_snapshots_update_own" on public.snapshots;
create policy "loop_snapshots_update_own"
  on public.snapshots for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "loop_snapshots_delete_own" on public.snapshots;
create policy "loop_snapshots_delete_own"
  on public.snapshots for delete
  to authenticated
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------- sync_state
create table if not exists public.sync_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  latest_snapshot uuid references public.snapshots(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.sync_state enable row level security;

drop policy if exists "loop_sync_state_select_own" on public.sync_state;
create policy "loop_sync_state_select_own"
  on public.sync_state for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "loop_sync_state_insert_own" on public.sync_state;
create policy "loop_sync_state_insert_own"
  on public.sync_state for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "loop_sync_state_update_own" on public.sync_state;
create policy "loop_sync_state_update_own"
  on public.sync_state for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ---------------------------------------------------------------- Data API grants
-- Supabase 2026: tables created via SQL may not be exposed to PostgREST
-- without explicit grants. RLS policies still decide which rows are visible.
grant usage on schema public to anon, authenticated;

-- anon only needs SELECT so the table is visible to the Data API before login;
-- RLS has no anon policies, so it still cannot read any rows.
grant select on table public.profiles,
                     public.devices,
                     public.snapshots,
                     public.sync_state
  to anon;

grant select, insert, update, delete
  on table public.profiles,
           public.devices,
           public.snapshots,
           public.sync_state
  to authenticated;

alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

notify pgrst, 'reload schema';

