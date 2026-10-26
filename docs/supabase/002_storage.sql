-- Loop 云端快照：Storage bucket + 访问策略
-- 如果这里报 permission denied，跳过本文件，在 Dashboard -> Storage 手动创建私有 bucket loop-snapshots，
-- 再用 Storage Policies 添加：
--   select/insert/update/delete: (storage.foldername(name))[1] = auth.uid()::text

-- 私有 bucket；文件路径必须是 <user_id>/<snapshot_id>/part-xxxxx
insert into storage.buckets (id, name, public)
values ('loop-snapshots', 'loop-snapshots', false)
on conflict (id) do update set public = false;

drop policy if exists "loop_storage_select_own" on storage.objects;
create policy "loop_storage_select_own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'loop-snapshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "loop_storage_insert_own" on storage.objects;
create policy "loop_storage_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'loop-snapshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "loop_storage_update_own" on storage.objects;
create policy "loop_storage_update_own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'loop-snapshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'loop-snapshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "loop_storage_delete_own" on storage.objects;
create policy "loop_storage_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'loop-snapshots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
