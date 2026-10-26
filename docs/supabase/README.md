# Supabase 配置清单（Loop 方案 B）

> 配置完成后回复「SQL 完成 + 测试账号已建」，我再接 Loop 客户端代码。
> **不要**把 anon key / 密码 / service_role key 发到聊天里。

---

## 1. 创建项目

1. 打开 https://supabase.com/dashboard
2. 新建项目（建议选离你近的区域）
3. 记下两样：

```text
Project URL: https://xxxx.supabase.co
anon public key / publishable key: sb_publishable_...
```

不要用 `service_role` / `sb_secret_...`。

免费额度注意：当前数据约 374MB，保留 2 份约 750MB；Supabase 免费 Storage 通常约 1GB，比较紧。若上传失败/超额，建议升级 Pro 或先只保留 1 份。代码会分片上传（16MB/片），不依赖单文件 50MB 限制。

---

## 2. 创建单用户账号

1. Authentication → Providers → Email 保持开启
2. Authentication → Users → Add user
   - 填你的邮箱
   - 设置密码（或发邀请）
   - 确认邮箱（如项目要求）
3. 创建完成后，到 Authentication → Settings 关闭公开注册（Allow new users to sign up = off），避免别人注册。

这个账号只给你自己用。

---

## 3. 建私有 Storage bucket

SQL 会尝试自动建 `loop-snapshots`；如果 SQL 编辑器没有权限操作 `storage.buckets`：

1. Storage → New bucket
2. Name：`loop-snapshots`
3. Public：**关闭**
4. 保存

不要开 Public。

---

## 4. 执行 SQL（分两段，先核心表）

> 不要一次执行整份 `001_init.sql`：Storage 策略在部分项目会因权限不足导致整批回滚。

### 4.1 核心表

1. SQL Editor → New query
2. 粘贴并执行 [001_core.sql](001_core.sql)
3. 应看到 `Success. No rows returned`

### 4.2 Storage

1. 先到 Storage → 新建私有 bucket `loop-snapshots`（Public 关闭）
2. 再执行 [002_storage.sql](002_storage.sql)
3. 如果策略仍报 `permission denied`：不要重试整份 SQL，改到 Storage → Policies 按下面规则手动添加：
   - 允许 `select/insert/update/delete`
   - 条件：`(storage.foldername(name))[1] = auth.uid()::text`

核心表会创建：

- `profiles`
- `devices`
- `snapshots`
- `sync_state`
- RLS 策略
- Storage 访问策略（只能访问自己的 `<user_id>/...`）

---

## 5. 验证

先确认 Table Editor → public 下能看到四张表。

在 SQL Editor 执行：

```sql
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('profiles','devices','snapshots','sync_state');
```

应看到四张表且 `rowsecurity = true`。

再看 bucket：

```sql
select id, name, public from storage.buckets where id = 'loop-snapshots';
```

应为 `public = false`。

用刚建的账号登录 Loop 后，客户端会：

1. 注册设备
2. 创建 `sync_state`
3. 上传第一份加密快照

---

## 6. 需要你保管的东西

| 项目 | 存放位置 | 是否给 Loop |
|---|---|---|
| Project URL | 本机 Loop 设置 | 是 |
| anon/publishable key | 本机 Loop 设置 | 是 |
| 登录邮箱/密码 | 你的密码管理器 | 登录时输入 |
| 同步口令 | 你的密码管理器 | 只用于本地加密，**不上传** |
| service_role key | 不要使用 | 否 |

---

## 7. 本轮确认的配置

- 单用户
- 包含资料 `files/`
- 保留 2 份快照
- 退出 Loop 时自动同步（上传完成后才能退出；会显示进度）

---

## 8. 配置完成后

回复：

```text
SQL 完成，测试账号已建；Project URL 和 anon key 已在本地准备好
```

不要贴 Key。之后我会：

1. 加 Supabase 登录/设备注册/设置页
2. 实现 SQLite 一致性快照 + 资料打包
3. 分片 AES-256-GCM 加密上传
4. 下载/恢复/冲突提示
5. 用你的测试账号跑上传→换设备→恢复演练
