# Loop v0.8.7

## 新功能：Supabase 加密快照同步（单用户）

- 设置 → 云端同步：填写 Supabase Project URL + publishable/anon key，登录测试账号
- 手动「立即上传」或退出 Loop 时自动上传
- SQLite 一致性快照（`VACUUM INTO`）+ 资料/技能/迁移打包
- Argon2id 派生密钥 + AES-256-GCM 8MB 分片加密
- 只保留云端最新 2 份快照
- 另一台设备「从云端恢复」→ 下载/校验/解密/解包 → 下次启动替换 `data/`
- 恢复前自动备份到 `data/.backup`，替换后做 SQLite `integrity_check`，失败回滚
- 单写冲突检测：其它设备有更新时阻止覆盖；手动上传可选择强制覆盖
- 登录后自动探测 Storage 写入/读取/删除权限，提前发现 bucket 策略问题
- 设置卡片可折叠，窄窗口无 overflow

## 配置

1. 按 [Supabase 配置清单](docs/supabase/README.md) 创建项目、Auth 用户、私有 bucket
2. 执行：
   - `docs/supabase/001_core.sql`
   - `docs/supabase/002_storage.sql`（Storage 策略）
3. Loop 设置页填写 URL/anon key，登录，输入同步口令

**不要使用 service_role key；同步口令不上传、不落盘。**

## 验证

- `flutter analyze`：0 issues
- 测试：**476 passed / 1 skipped**
- Windows 构建通过
- 自动化覆盖：云端配置读写/拒绝 service_role、恢复替换与备份、完整性校验
- 真实 Supabase 上传/恢复需要配置账号后实测

## 已知限制

- 单用户、单写：多设备同时编辑不合并，冲突时阻止/强制覆盖
- 恢复必须重启 Loop 生效
- 免费 Supabase 存储约 1GB，2 份 374MB 快照接近上限，建议 Pro 或只保留 1 份
- 口令只保存在内存；退出同步没有口令会弹窗询问
- 关闭到托盘不算退出，不会触发同步
- 快照包含本地设置/API Key（整包加密）；如不希望同步 API Key，后续可加排除策略

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（21,420,878 B）
- ZIP SHA-256：`E60F677986032909720C5D22D04AB881971F7012E1CA7E1BAB78E1F455DA18F6`
- `Loop.exe` SHA-256：`2EBB6745D1018CD22060B1F435D1BC7D12435E39CE141058557EDA638C18C2BD`
- `version.json`：`{"version":"0.8.7"}`
