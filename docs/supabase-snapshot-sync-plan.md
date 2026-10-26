# Loop 云端方案 B：Supabase 单用户快照同步

> 你选：**B 快照同步**，**单用户**。
> 目标：多台设备依次使用；登录后上传/下载加密快照；不同地方可恢复同一份对话、设置、资料。
> 不是实时多端同时编辑；同一时间只允许一台设备写。

---

## 1. 先确认：Supabase API Key 用哪一个

Supabase 有两个关键 Key：

| Key | 用途 | 能否放 Loop 客户端 |
|---|---|---|
| **anon public key** | 客户端登录后按 RLS 访问自己的数据 | ✅ 可以，配合 RLS |
| **service_role key** | 绕过 RLS 的管理员权限 | ❌ **绝对不能**放客户端/截图/聊天 |

你手里如果是 **service_role**，不要用，也不要把完整 Key 发给我；请在 Supabase 控制台复制 **Project URL + anon public key**。

Loop 里不硬编码 Key：在本机设置页填写，保存到 Windows 凭据/本地配置，不提交到 GitHub。

---

## 2. 架构

```text
Loop 客户端（Windows）
  ├─ 本地 SQLite（继续离线可用）
  ├─ Supabase Auth（邮箱+密码，单用户）
  ├─ 快照引擎
  │    ├─ SQLite VACUUM INTO 一致性快照
  │    ├─ 资料/技能打包
  │    ├─ Argon2id 派生密钥 + AES-256-GCM 分块加密
  │    └─ Supabase Storage 分片上传
  └─ 恢复引擎（下载→校验→解密→下次启动替换 data/）

Supabase
  ├─ Auth：一个用户
  ├─ Postgres：devices / snapshots / sync_state
  └─ Storage 私有 bucket：加密分片
```

**服务端只看到密文和元数据**，看不到对话/资料内容，也看不到 API Key。

---

## 3. 数据模型（Supabase Postgres）

```sql
-- 用户资料
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text default '',
  created_at timestamptz default now()
);

-- 设备
create table public.devices (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  platform text default 'windows',
  last_seen_at timestamptz default now(),
  created_at timestamptz default now()
);

-- 快照
create table public.snapshots (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  created_at timestamptz default now(),
  app_version text not null,
  schema_version integer not null,
  total_bytes bigint not null,
  chunk_size integer not null,
  chunk_count integer not null,
  sha256 text not null,
  manifest jsonb not null,
  storage_prefix text not null,
  status text not null default 'uploading'  -- uploading / ready / failed
);

-- 当前最新快照（每用户一行）
create table public.sync_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  latest_snapshot uuid references public.snapshots(id),
  updated_at timestamptz default now()
);
```

RLS：每张表只允许 `auth.uid() = user_id`（`sync_state` 同）。Storage bucket 私有，对象路径必须以 `auth.uid()/` 开头。

当前 Loop 单用户，不建设多租户/团队权限；以后要多人再扩。

---

## 4. 快照内容

建议包含：

- 全局 `loop.db`（一致性快照，不含 WAL/SHM）
- `subjects/<key>/loop.db`
- `subjects/<key>/files/`（资料副本）
- `subjects/<key>/skills/`（教学技能）
- manifest：版本、设备、文件数、总字节、每块 SHA-256

建议排除：

- `data/trash/`、日志、缓存、临时上传
- **供应商 API Key / 密钥**：每台设备本地重新填写；不要上云
- 本机绝对路径、托盘图标等无关文件

当前数据约 **374MB**：数据库约 230MB，资料约 144MB。首次上传较大，所以用分片。

---

## 5. 加密与分片

- 用户设置一个**同步口令**（与 Supabase 登录密码不同）。
- 客户端用 **Argon2id**（或 PBKDF2 600k）派生 256-bit key；盐存 manifest。
- 快照按 16MB 分块，每块 **AES-256-GCM**；nonce/序号/认证标签写进块头。
- 每块上传前算 SHA-256；manifest 记录总哈希。
- Supabase 只存密文；没有口令无法恢复。
- 口令丢失 = 云端快照不可恢复；请自行放密码管理器。

分片还解决 Supabase Storage 单文件大小限制。

---

## 6. 上传流程

```text
登录（Supabase Auth）
  ↓
注册/更新设备
  ↓
检查是否已有正在上传的快照；有则续传
  ↓
暂停写入（或等待本轮 SSE/Agent 结束）
  ↓
备份数据目录：
  - SQLite: VACUUM INTO data/.sync/tmp/*.db
  - 复制 files/skills
  - 生成 manifest
  ↓
分块加密 → 逐块上传到 bucket/<user_id>/<snapshot_id>/part-000...
  ↓
全部成功后 snapshots.status = ready
  ↓
更新 sync_state.latest_snapshot
  ↓
清理旧快照（按保留策略）
```

“暂停写入”实现方式：

- 同步按钮点击后，UI 显示“正在准备快照”，阻止发送新消息/后台任务写入；
- 等待当前流式回答/导入结束后开始；
- 不做数据库在线热复制，避免 WAL 不一致。

恢复/备份期间若用户强制退出，下次启动清理 `.sync/tmp`，不覆盖正式数据。

---

## 7. 下载与恢复流程

```text
登录 → 读取 sync_state.latest_snapshot
  ↓
如果本地有未上传变更：提示“云端有更新，先上传还是先下载？”
  ↓
下载分片 → 校验 SHA-256 → 解密到 data/.sync/incoming
  ↓
写 pending-restore 标记
  ↓
提示重启 Loop
  ↓
下次启动（Backend.start 之前）：
  1. 备份当前 data/ 到 data/.backup/<timestamp>
  2. 校验 incoming
  3. 原子替换 data/
  4. 打开 SQLite 做 integrity_check
  5. 失败则回滚备份
  6. 清除 pending-restore
```

不在运行中直接替换 SQLite，避免数据库句柄/WAL 风险。

---

## 8. 冲突策略（单写）

- 同一时间只允许一台设备上传；上传前检查云端 `latest_snapshot` 是否比本机记录的更新。
- 如果云端更新：
  - 默认提示“下载最新”；
  - 用户可选择“用本机覆盖”，但会覆盖另一台设备的上传；
  - 不做自动合并。
- 设备 A 上传后，设备 B 再上传前必须先下载，否则提示冲突。
- 每台设备有 `device_id`，UI 显示设备名/最后同步时间。

这符合“单用户、多设备依次使用”，不是实时协同。

---

## 9. 认证与密钥存储

- Supabase Auth：邮箱+密码（或 magic link）。
- 单用户：注册一个账号后可在控制台关闭公开注册。
- 客户端保存 refresh token 到 **Windows 凭据管理器/DPAPI**，不存明文 SQLite。
- Supabase URL/anon key 存本地设置，不提交仓库。
- 同步口令单独派生，不存服务器。
- 不把 service_role key 打进安装包。

---

## 10. 我会做什么

### 阶段 1：Supabase 基础设施（1–2 天）

- 给出一份 SQL migration（表、RLS、Storage 策略）
- 给出 bucket 配置步骤
- 验证 anon key + RLS：用户只能访问自己的行/对象
- 说明免费/Pro 配额（当前 374MB，建议只保留最近 2–3 份）

### 阶段 2：客户端登录与设备（2–3 天）

- 设置页新增“云端同步”：Supabase URL、anon key、登录、退出
- 设备名/device_id、最后同步时间
- token 安全保存
- 未登录不启用同步

### 阶段 3：上传快照（4–5 天）

- 一致性快照（SQLite `VACUUM INTO`）
- files/skills 打包；manifest
- 分块 AES-256-GCM 加密
- Supabase Storage 分片上传、失败续传、哈希校验
- 旧快照保留/清理

### 阶段 4：下载与恢复（4–5 天）

- 分片下载、校验、解密
- pending-restore + 下次启动替换
- 当前数据备份、integrity_check、失败回滚
- 冲突提示/设备同步状态 UI

### 阶段 5：测试/发布（3–5 天）

- 使用你的 Supabase 测试项目 + 测试数据副本
- 上传/下载/中断/续传/损坏/口令错误/回滚
- 两台设备依次同步演练
- 文档、README、版本发布

预计 **3–4 周**（1 人；资料 374MB 首次上传会占时间）。

---

## 11. 你需要做什么

### 立即

1. 在 Supabase 确认 Key 类型：要 **anon public key**，不要 service_role。
2. 创建/选择一个 **测试项目**（不要先用正式数据）。
3. 开启 Email Auth；创建你的单用户账号；关闭公开注册。
4. 创建一个**私有** Storage bucket（名字例如 `loop-snapshots`）。
5. 准备一个**同步口令**，存密码管理器；不要发给我。
6. 决定：
   - 是否包含 `files/` 资料文件（当前约 144MB）；
   - 保留几份快照（建议最近 2–3 份）；
   - 手动同步，还是退出时自动上传。

### 稍后

- 在本机安装/登录 Supabase 控制台（或给我 SQL，你在 SQL Editor 执行）。
- 第一次真实上传前关闭 Loop。
- 用测试项目先跑完整恢复演练，再切正式。

---

## 12. 风险与边界

- **不是实时同步**：两台设备同时编辑同一对话会冲突；只能一台写。
- **Supabase 免费额度有限**：1GB storage 左右；374MB 只能存少量快照，建议 Pro 或只保留最新 1–2 份。
- **口令丢失无法恢复**；这是端到端加密的代价。
- **API Key 不同步**；每台设备本地填写。
- **服务端仍能看到元数据**：设备名、快照时间、大小、文件数量。
- 不把 service_role key、密码、同步口令写进代码/仓库/聊天。

---

## 13. 下一步

你确认以下 4 项后，我开始阶段 1：

1. 使用 **anon public key**（不是 service_role）；
2. 是否包含资料 `files/`；
3. 快照保留几份；
4. 同步触发：手动 / 退出时 / 每天。

然后我会先给你 Supabase SQL migration 和配置清单；你执行并创建测试账号后，我再接客户端代码。
