# 学科（Subject）教学 Skill 生态调研

> 目标版本：Loop v0.8.0 · 学科功能
> 调研时间：2026-10-25（Asia/Shanghai）
> 调研人：skills-engineer（AgentTeams: loop-subject-v0.8）
> 交付物：本文档为 t2 的产出，后续 skill 安装器实现以此为契约。

本文所有结论均标注来源。**实测**＝本次调研直接请求 / 读取源码得到的可复现结果；**文档**＝官方文档声明但本次未独立验证；**未知**＝本次无法确认，实现时不得假设。

---

## 0. 结论速览（TL;DR）

| # | 结论 | 依据 |
|---|---|---|
| 1 | EduHub 是一个**开放教学 skill registry**，协议兼容 [ClawHub](https://clawhub.ai)，两者共用 `/api/v1` 读接口形状 | 实测 + [overview](https://eduhub.deeptutor.info/how-to-use/overview) |
| 2 | skill 包 = 一个目录，根级必须有 `SKILL.md`（YAML frontmatter + markdown 正文）+ 可选资源文件 | [skill-format.md](https://eduhub.deeptutor.info/skill-format.md) |
| 3 | **搜索/安装无需登录，发布需登录**。我们用只读接口即可完成「按用户选择下载教学 skill」 | [overview](https://eduhub.deeptutor.info/how-to-use/overview) + 实测 401/200 |
| 4 | 制品是**纯文档 zip**，服务端规范化重打包并给出**逐文件 sha256 清单**，我们可离线校验完整性 | 实测（9/9 匹配） |
| 5 | 官方 `eduhub` CLI（npm，v0.1.7）的 `install` **没有任何安全门**：直接 `extractAllTo` 落盘 | 实测源码 `dist/commands/install.js` |
| 6 | DeepTutor 自己的导入门才是正确的参考实现：verdict 判定 → zip-slip/bomb 防护 → 后缀白名单 → 原子替换 → 来源记账 | 实测源码 `services/skill/hub.py`、`service.py` |
| 7 | 包**无数字签名**（`signature.status = "unsigned"`），完整性只能靠 sha256 清单，不能靠签名 | 实测 `/verify` |
| 8 | 官方 CLI 与官方文档存在**语言取值不一致**：文档/交互提示含 `ja`/`other`，但 CLI 校验只接受 `zh`/`en` | 实测（`--language ja` 被拒） |
| 9 | Loop 仓库目前**没有任何 skill / eduhub / clawhub 相关代码**，属全新实现 | 实测仓库扫描 |

**给实现的一句话建议**：不要 `npm i -g eduhub` 让 CLI 装到工作区。应自己在 Python server 侧实现「verify → 下载 → 校验 sha256 → zip 防滑/防炸 → 后缀白名单 → 原子替换 → 记账」的导入管线（照抄 DeepTutor 的安全姿态），把 skill 落到**学科自己的目录**下，Flutter 侧只做"浏览/勾选/确认"的极简 UI。

---

## 1. 调研范围与方法

### 1.1 覆盖范围

- EduHub 站点：`/skills`、`/how-to-use/overview`、`/how-to-use/any-agent`、`/how-to-use/with-deeptutor`、`/how-to-use/prepare`、`/how-to-use/publish`、`/how-to-use/maintain`、`/how-to-use/agent-publish`、`/how-to-use/deeptutor`
- EduHub 规范原文：`/skill-format.md`、`/eduhub-skill-manager.md`
- ClawHub 协议：`clawhub.ai` 站点与其公开 `/api/v1`
- `eduhub` CLI：npm 包源码（v0.1.7 全量反编译阅读）
- 可借鉴项目：`HKUDS/DeepTutor`（服务端 + CLI + Web 实现）、`openclaw/clawhub`、`openclaw/agent-skills`、`anthropics/skills` 及教学类 skill 仓库

### 1.2 方法

1. 直接抓取官方文档页面与规范原文；
2. 对 registry `/api/v1` 做**只读探测**（GET，无鉴权），记录真实响应；
3. 下载 `eduhub` CLI npm tarball，通读编译产物以还原真实端点、配置路径、锁文件与安全行为；
4. 用 GitHub Contents API 取 DeepTutor 关键源码，定位其导入门与回滚语义；
5. 用真实 CLI 对一个自建样例包跑 `--dry-run`，做端到端结构验证。

### 1.3 不可访问 / 未验证（**实现时不得假设**）

| 项 | 状态 | 说明 |
|---|---|---|
| `docs.openclaw.ai/clawhub/*` 文档正文 | 未能抓取 | 页面正文未渲染完成，只能拿到导航。ClawHub 协议细节主要用 EduHub 规范 + 实测 API 反推 |
| `raw.githubusercontent.com` | 不可达 | 本环境解析到非公网 IP；改用 GitHub Contents API 取源码 |
| `web_search` 工具 | 不可用 | 返回 HTTP 401（搜索端点与 chat 端点分离）。本次未使用搜索引擎 |
| EduHub 目录超过 77 条 | 未知 | `?limit=200` 只回 77 条；`?offset=` / `?page=` / `?cursor=` 均被忽略（仍回 50 条）。**是否存在游标分页未知** |
| `ok:false` / `decision != "pass"` 的真实样本 | 未观测到 | 5 个抽样 skill 全为 `ok:true, decision:"pass"`。被拦截包的真实返回体未验证 |
| `decision` 取值全集 | 未知 | 仅观测到 `"pass"`；规范提到扫描命中会让 verdict 从 `pass` 翻成 `review`，但未实测 |
| EduHub 是否服务端强制 4MB/40MB/600 文件上限 | 文档声明，未独立验证 | 因发布需登录，本次未发布验证 |
| EduHub `/api/v1/skills?owner=me` | 需鉴权 | 未带 token 返回 **400** |
| ClawHub `/api/v1/taxonomy`、`/categories` | 不存在 | 均 404；ClawHub 无分类词表端点，EduHub 有 |
| ClawHub `/api/v1/skills/{slug}`（不带 owner） | 不可用 | 404；`/download` 不带 `ownerHandle` 对歧义 slug 返回 **409** |
| `virusTotal` / `skillSpector` / `dependencyRegistry` 信号 | 恒为 `null` | EduHub 与 ClawHub 抽样均未提供这些信号 |
| GitHub 导入来源（provenance） | 恒为 `unavailable` | 5 个抽样均返回 `{"source":"unavailable","reason":"This mirror stores no GitHub import provenance."}` |
| `eduhub` CLI 的 `pinned` 字段 | 只读不写 | `update` 会跳过 `pinned` 的 skill，但没有任何命令设置它 |

---

## 2. Registry 与协议总览

### 2.1 两个 registry、一套形状

| Registry | Web | API base | 关系 |
|---|---|---|---|
| **EduHub**（教学专用，DeepTutor 官方） | `https://eduhub.deeptutor.info` | `https://eduhub.deeptutor.info/api/v1` | 兼容 ClawHub 协议，多了教学分类词表 |
| **ClawHub**（OpenClaw 生态通用） | `https://clawhub.ai` | `https://clawhub.ai/api/v1` | 上游协议与站点 |

- EduHub 自述："EduHub is an open registry of teaching skills that speaks the ClawHub protocol — package teaching ability as skills and drop them into any agent."（[overview](https://eduhub.deeptutor.info/how-to-use/overview)）
- 规范原文："EduHub 兼容 [ClawHub](https://clawhub.ai) 协议：一个技能由一个 `slug` 标识，挂多个 semver 版本，`dist-tags.latest` 指向当前推荐版本。"（[skill-format.md](https://eduhub.deeptutor.info/skill-format.md)）
- DeepTutor 源码把两者实现为同一个 provider 类，仅 base_url 不同（**实测** `deeptutor/services/skill/hub.py`）：

```python
_CLAWHUB_BASE_URL = "https://clawhub.ai/api/v1"
_EDUHUB_BASE_URL  = "https://eduhub.deeptutor.info/api/v1"
```

- 引用语法为 `<hub>:<slug>[@version]`，支持发布者限定 `<hub>:<ownerHandle>/<slug>[@version]`（**实测** hub.py 模块 docstring）。示例：`eduhub:socratic-tutor@1.0.0`。

### 2.2 关键身份语义

- **slug**：小写、`^[a-z0-9][a-z0-9._-]{0,127}$`（**实测** CLI `validateSlug`）。
- **版本**：semver，`^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$`（**实测** CLI `validateSemver`）。
- **归属**：slug 一旦存在，只有 owner（或管理员）能发新版本/编辑/回退。frontmatter 里的 `author` 会被忽略，owner 以发布登录身份为准（[skill-format.md §3.2](https://eduhub.deeptutor.info/skill-format.md)）。

---

## 3. Skill 包格式

### 3.1 目录结构

```text
my-skill/
├── SKILL.md            # 必需，且必须在包的根级
├── reference.md        # 可选：补充资料、知识库、提示词片段
├── examples/           # 可选：示例对话、样题、范文
│   └── example-1.md
└── scripts/            # 可选：纯文本脚本（见 §7 安全红线）
    └── helper.py
```

规则（[skill-format.md §2](https://eduhub.deeptutor.info/skill-format.md)）：

- `SKILL.md` 必须存在且在**根级**，缺失即拒绝（网页表单代生成除外）。
- **单层壳目录会被自动拍平**：发布时若所有文件都在 `my-skill/` 下，会自动剥壳让 `SKILL.md` 落到根级。
- 隐藏文件（`.` 开头）与 `__MACOSX/` 自动忽略。

### 3.2 SKILL.md = YAML frontmatter + Markdown 正文

正文是**给模型的可执行剧本**，不是给人读的产品文档（规范原文）。

### 3.3 frontmatter 字段

| 字段 | 必填 | 类型 | 说明 |
|---|---|---|---|
| `name` | ✅ | string | 展示名；缺省 slug 时用于推导 slug |
| `description` | ✅ | string | 一句话能力描述，**写清"做什么 + 何时用"**，是 agent 判断是否启用的关键 |
| `track` | ✅（发布时） | enum | 主类目，四选一，闭合词表 |
| `language` | ✅（发布时） | enum | 默认 `zh` |
| `domains` | 可选 | string[] | 领域，**开放词表**，可多选；空 = 跨领域通用 |
| `stages` | 可选 | string[] | 学段，多选；空 = 全学段 |
| `forms` | 可选 | string[] | 交互形式，多选 |
| `version` | 可选 | semver | 不写则发布时用 `--version` 或交互填 |
| `tags` | 可选 | string[] | 自由关键词（**仅参与搜索**） |
| `license` | 可选 | string | 如 `MIT`、`CC-BY-4.0` |
| `installCommand` | 可选 | string | 自定义安装提示命令 |
| `changelog` | 可选 | string | 本版本变更说明 |
| `longDescription` | 可选 | string | 详细介绍 |
| `author` | — | — | **会被忽略**，归属以发布登录身份为准 |
| `always` | — | bool | DeepTutor 本地字段；**导入时会被剥离**（见 §7.4） |

### 3.4 分类词表（taxonomy）

EduHub 有独立词表端点（**实测** `GET /api/v1/taxonomy` → 200）：

```
track    : academics | companions | skills-interests | educators            （闭合，4 值）
language : zh | en                                                          （预设 2 值，文档称开放）
stages   : preschool | k12 | university | adult                             （开放，预设 4 值）
forms    : companion | tutor | practice | tool                              （开放，预设 4 值）
domains  : stem | languages | humanities | arts | business | life | general （开放，预设 7 值）
```

- `track` 是**唯一闭合**词表，其余为开放词表，可填任意字符串（如 `考研数学`）。
- 规范里所有取值以**英文小写 token** 为准，中文只是展示标签。
- ⚠️ **文档与 CLI 不一致（实测）**：`/eduhub-skill-manager.md` §3 列出语言为 `zh/en/ja/other`，CLI 交互提示也列出 `ja`/`other`，但 `dist/lib/pkg.js` 的 `validateLanguage()` 只接受 `zh|en`。实测 `--language ja` → `❌ language must be one of: zh / en`，exit 1。
  **实现建议**：Loop 侧只暴露 `zh`/`en`，把其他语言当未知值只读展示，避免踩这个坑。

### 3.5 打包与体积约束（硬性）

| 约束 | 上限 / 规则 |
|---|---|
| 必须包含 `SKILL.md` | 且位于根级（壳目录自动拍平） |
| 单个文件大小 | ≤ 4 MB |
| 包内总大小 | ≤ 40 MB |
| 文件数量 | ≤ 600 |
| 路径安全 | 禁止绝对路径与 `..`（zip-slip 防护），命中直接拒绝 |
| 自动忽略 | 隐藏文件（`.` 开头）、`__MACOSX/` |

（[skill-format.md §5](https://eduhub.deeptutor.info/skill-format.md)，DeepTutor 的本地预检 `preflight_skill_dir` 镜像了同一组数字——**实测** hub.py）

### 3.6 规范化重打包与完整性清单

发布后制品会被**规范化重打包**：拍平壳目录、**按字节为每个文件计算 `sha256` 清单**，`/download` 端点永远吐回这个无壳、合法的规范包（[skill-format.md §5](https://eduhub.deeptutor.info/skill-format.md)）。

**本次已独立验证该清单可用（实测）**：

- 下载 `learn-ai-architect@1.0.0`（`GET /api/v1/download?slug=learn-ai-architect&version=1.0.0`）
- 对解压出的 9 个文件逐一计算 sha256，与 `GET /api/v1/skills/learn-ai-architect?files=true` 的 `files[].sha256` 比对 → **9/9 全部匹配，0 不一致**
- zip 条目数 9 = 清单条目数 9

```
OK      1041  ATTRIBUTION.md                   d02012d85658...
OK      1072  LICENSE                          02f9ec4b111c...
OK      1793  references/improvement-loop.md   c8aff5f99e07...
OK      2512  references/integration.md        2f85dfd20876...
OK      1239  references/ledger-examples.md    189224030816...
OK      1821  references/lesson-contract.md    6710c6335a86...
OK      1735  references/routing.md            1a924c021c48...
OK      7962  scripts/academy_state.py         5d5ed0046d8c...
OK      4807  SKILL.md                        b7e6022bdb1c...
MATCH=9 MISMATCH=0
```

制品 sha256（可复现）：

| 制品 | sha256 |
|---|---|
| `socratic-tutor@1.0.0` zip（1106 B） | `DCA541FBF67B48F14BC0B36F4E6D5C38ECC3634E323E5867E6394A8A071675F2` |
| `learn-ai-architect@1.0.0` zip | `0DDE17CE45C9532A9D71EA56E0B43D08F8683EDEDA3C247C3142EBC28EBF3E2F` |

---

## 4. Registry API（全部实测）

### 4.1 只读端点（无需登录）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/skills?limit=&sort=` | 目录列表，默认 **50** 条。`sort` 被 DeepTutor 客户端使用（`sort=createdAt`） |
| GET | `/api/v1/search?q=&limit=&track=` | 关键词搜索，返回带 `score` 的相关度排序 |
| GET | `/api/v1/skills/{slug}?version=&tag=&files=true` | 单个 skill 详情；`files=true` 附带 sha256 清单 |
| GET | `/api/v1/skills/{slug}/verify?version=&tag=&ownerHandle=` | **安全裁决**（见 §4.3） |
| GET | `/api/v1/download?slug=&version=&tag=&ownerHandle=` | 下载规范化 zip（`Content-Type: application/zip`） |
| GET | `/api/v1/taxonomy` | 分类词表（EduHub 独有；ClawHub 404） |

### 4.2 鉴权端点（发布/维护用，Loop v0.8.0 **不需要**）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/whoami` | 无 token → **401**（实测） |
| GET | `/api/v1/skills?owner=me` | 无 token → **400**（实测） |
| POST | `/api/v1/skills` | multipart 发布：`zip` + `slug` + `version` + `track`(必填) + 分类字段；`Authorization: Bearer <token>` |
| POST | `/api/v1/skills/{slug}/dist-tags` | `{"tag":"latest","version":"1.0.0"}` 移动 tag = 回退 |
| DELETE | `/api/v1/skills/{slug}` | 删除（仅 owner/管理员） |
| GET | `/api/auth/cli-login?cli_port=&cli_state=` | 浏览器授权铸 token（本地 127.0.0.1 回调 + state 校验） |

（端点清单来自实测 + [skill-format.md §8](https://eduhub.deeptutor.info/skill-format.md) + CLI 源码）

### 4.3 `verify` 响应（`clawhub.skill.verify.v1`）

实测返回体（截取关键字段）：

```json
{
  "schema": "clawhub.skill.verify.v1",
  "ok": true,
  "decision": "pass",
  "reasons": [],
  "slug": "socratic-tutor",
  "displayName": "Socratic Tutor",
  "publisherHandle": "deeptutor",
  "version": "1.0.0",
  "resolvedFrom": "tag",
  "tag": "latest",
  "card": { "available": false },
  "artifact": { "files": [ { "path": "SKILL.md", "size": 1856,
                             "sha256": "d7b01e57...", "contentType": "text/markdown" } ] },
  "provenance": { "source": "unavailable",
                  "reason": "This mirror stores no GitHub import provenance." },
  "security": {
    "status": "clean", "passed": true, "rawStatus": "clean",
    "verdict": "benign", "confidence": "low",
    "summary": "Static scan found no high-signal malicious patterns. Not a full malware scan.",
    "model": "eduhub-static-scan", "checkedAt": 1792906435820,
    "signals": { "staticScan": { "status": "clean", "reasonCodes": [], "findings": [] },
                 "virusTotal": null, "skillSpector": null, "dependencyRegistry": null }
  },
  "signature": { "status": "unsigned" }
}
```

**裁决语义（DeepTutor 的判读规则，实测 hub.py + test_skill_hub.py）**：

```python
if payload.get("ok") is True:  -> "ok"          # 可安装
else:                          -> "suspicious"  # 默认拒装，除非显式 allow_unverified
# 网络/协议失败                  -> "unknown"     # 降级警告，不阻断
```

- 测试用例印证：`{"ok": true, "decision": "clean"}` → `ok`；`{"ok": false, "decision": "malware"}` → `suspicious`；传输失败 → `unknown`，**永不抛异常**。
- ⚠️ `confidence` 在实测中是 `"low"`（ClawHub 同样包给到 `"high"`），`summary` 明说 "Not a full malware scan"。**不要把 `decision: pass` 当作安全保证**。
- ⚠️ `signature.status = "unsigned"`：**没有包签名**，不能作为信任锚。

### 4.4 `search` 响应

```json
{ "results": [ { "score": 6, "slug": "socratic-tutor", "displayName": "Socratic Tutor",
                 "summary": "...", "version": "1.0.0", "updatedAt": 1781529724776,
                 "ownerHandle": "deeptutor",
                 "owner": { "handle": "deeptutor", "displayName": "DeepTutor",
                            "image": "/logo.png", "userId": "official:deeptutor",
                            "htmlUrl": "https://deeptutor.info" } } ] }
```

- `track` 过滤**生效**（实测：`q=tutor` 13 条 → 加 `track=academics` 12 条，差异项为 `learn-ai-architect`）。
- `limit` 生效（`limit=3` → 3 条）。
- ⚠️ `search` 结果**不含** `language` / `domains` / `stages` / `forms` 与 license，做 UI 筛选需再调详情。
- ⚠️ 目录列表 `/api/v1/skills` 的条目字段仅为：
  `slug, displayName, summary, version, updatedAt, createdAt, stats, ownerHandle, owner`
  ——**无 track/language/domain**。因此"按学科领域筛选"要么走 `search`+`track`，要么对候选逐个拉详情（有 N+1 成本）。

### 4.5 详情响应结构

```json
{ "skill": { "slug", "displayName", "summary", "description"/* = SKILL.md 全文 */,
             "tags": { "latest": "1.0.0" } /* 注意：这是 dist-tags map，不是话题标签 */,
             "keywords": [...] /* 话题关键词在这里 */,
             "stats": { "downloads", "installsAllTime", "installsCurrent",
                        "stars", "comments", "versions" },
             "createdAt", "updatedAt" },
  "latestVersion": { "version", "createdAt", "changelog", "license" },
  "metadata": { "setup": [], "os": null, "systems": null },
  "owner": { "handle", "displayName", "image", "userId", "htmlUrl" },
  "moderation": null,
  "versions": ["1.0.2", "1.0.1", "1.0.0"],
  "distTags": { "latest": "1.0.2" },
  "files": [ { "path", "size", "sha256", "contentType" } ]   // 仅 ?files=true
}
```

⚠️ **字段陷阱**：`skill.tags` 是 **dist-tags map**（`{"latest": "1.0.0"}`），话题标签在 `skill.keywords`。DeepTutor 源码里有明确注释说明这个坑（实测 hub.py:496-501）。

### 4.6 实测的 registry 规模与内容画像

- `/api/v1/skills?limit=200` → **77 个 skill**（默认无 `limit` 时只回 50）。
- 多版本 skill：`learn-to-apply`（3 版）、`s11-model-tree-four-steps`（2 版）。
- 真实包形态样本（`?files=true` 实测）：

| slug | 文件数 | 形态要点 |
|---|---|---|
| `socratic-tutor` | 1 | 纯 `SKILL.md`（官方最小样例） |
| `unblock-reading` / `explain-it-back` / `learn-to-apply` | 2 | `SKILL.md` + `agents/openai.yaml` |
| `evidence-based-k12-math-lesson` | 8 | `SKILL.md` + `ATTRIBUTION.md` + `references/*.md` ×6 |
| `learn-ai-architect` | 9 | `SKILL.md` + `ATTRIBUTION.md` + `LICENSE` + `references/*.md` ×5 + `scripts/academy_state.py` |
| `clawhub-studying` | 17 | `SKILL.md` + `LICENSE` + `_meta.json` + `EDUHUB_SOURCE.md` + 12 个主题 `.md` |
| `clawhub-socraticmathcoach` | 7 | `SKILL.md` + `LICENSE` + `README.md` + `_meta.json` + `EDUHUB_SOURCE.md` + `skill-card.md` + `test-examples.md` |

> 注意 `learn-ai-architect` 内含 `scripts/academy_state.py`（7962 B）且 verdict 仍为 `pass`。**说明 registry 允许打包文本脚本**——这与"禁止任意代码执行"不冲突，但要求**我们这一侧**保证永不执行它们（见 §7）。

### 4.7 ClawHub 与 EduHub 的差异（实测，**必须做兼容处理**）

| 维度 | EduHub | ClawHub |
|---|---|---|
| 列表端点 | `GET /skills` → `{"skills":[…]}` | `GET /skills` → `{"items":[…], "nextCursor":"…"}` |
| 分页 | 无游标（`offset`/`page` 被忽略） | **有 `nextCursor`**（游标式） |
| 单条详情 | `GET /skills/{slug}` 直接可用 | `GET /skills/{slug}` → **404**；需 `ownerHandle` |
| 下载 | `/download?slug=&version=` | `/download?slug=&ownerHandle=`；**歧义 slug 不带 owner 返回 409** |
| verify | `/skills/{slug}/verify` | `/skills/{slug}/verify?ownerHandle=`（同 schema） |
| 分类词表 | `/taxonomy` 有 | `/taxonomy`、`/categories` 均 404 |
| 卡片 | `card.available=false` | `card.available=true`，指向 `skill-card.md` |
| 富字段 | 较少 | 多 `install.kind/reference`、`trust.*`、`native.*`、`isSuspicious` |
| 安全裁决 | `confidence: "low"`, `model: "eduhub-static-scan"` | `confidence: "high"`, `model: null`, 多 `scannerReports` |

**兼容建议**：解析列表时按 `results → skills → items` 顺序探测键名，详情/下载统一走"`<hub>:<owner?>/<slug>` 引用 + 参数化 ownerHandle"，与 DeepTutor 的做法一致（**实测** hub.py:324-331、458-462 的键名探测循环）。

---

## 5. CLI 与集成方式

### 5.1 `eduhub` CLI（npm，任意 agent 用）

- 包名 `eduhub`，最新 **0.1.7**（2026-06-19 发布），维护者 `zzhtx` / `bingxi`，`engines.node >= 18`（实测 npm registry metadata）。
- 依赖：`adm-zip`、`commander`、`env-paths`、`gray-matter`。
- ⚠️ npm 元数据里 **没有 repository / homepage / readme**（`"readme":"ERROR: No README data found!"`）——**闭源**，只能读编译产物。

命令表（实测 `dist/index.js` 全量）：

```bash
eduhub --registry <url> --workdir <dir> --no-input   # 全局选项
eduhub login [--token <t>] [--registry <url>] [--timeout <s>] [--no-open]
eduhub logout
eduhub whoami
eduhub search <query...> [--limit <n>]               # 默认 25
eduhub install <slug> [--version <v>] [--tag <t>] [--workdir <d>] [--dir <d>]
eduhub list
eduhub update [slug] [--all] [--workdir <d>] [--dir <d>]
eduhub skill publish <path> [--slug --name --version --track --language --author
                             --changelog --tags --domains --stages --forms
                             --audiences --install-command --dry-run]
eduhub skill inspect <slug> [--version --tag --files --json]
eduhub skill delete <slug> --yes
```

配置与状态文件（实测）：
- 配置目录：`env-paths("eduhub", {suffix:""}).config` → Windows 上为 `%APPDATA%\eduhub\Config\config.json`；文件内 `{ "registry": "...", "token": "..." }`。
- registry 解析优先级：`EDUHUB_REGISTRY` 环境变量 → 配置文件 `registry` → `https://eduhub.deeptutor.info`。
- **安装锁文件：`<workdir>/.eduhub/lock.json`**，形如：

```json
{ "skills": { "socratic-tutor": { "slug": "socratic-tutor",
                                  "version": "1.0.0",
                                  "installedAt": "2026-10-25T05:00:00.000Z" } } }
```

（`pinned` / `pinReason` 会被 `update` 读取并跳过，但**没有任何命令能写入它们**——实测）

### 5.2 `eduhub` CLI 的三个硬伤（实测源码，**不要直接依赖**）

1. **`install` 没有安全门**。`dist/commands/install.js` 直接 `new AdmZip(buf).extractAllTo(targetDir, true)`——没有调 `/verify`、没有 zip-slip 检查、没有 zip-bomb 上限、没有后缀白名单。它会无条件把压缩包里的任意路径/任意类型文件落到工作区。
2. **`install` 不校验 sha256**。虽然详情接口给了逐文件 `sha256` 清单，CLI 完全没用。
3. **覆盖式写入**。安装前 `fs.rmSync(targetDir, {recursive:true, force:true})`，中途失败会留下**已被删除的旧版本**——没有原子替换、没有回滚快照。

> 结论：**Loop 不应把 `eduhub` CLI 作为安装器**。它可以作为"人类用户的自助工具"，但 Loop 内的导入必须走自建安全管线。

### 5.3 `deeptutor` CLI（DeepTutor 内建）

```bash
deeptutor skills search "socratic"
deeptutor skills install <slug>            # 或 <slug>@1.0.0
deeptutor skills install <slug> --allow-unverified
deeptutor skills list                      # 已装列表（来源 & 版本）
deeptutor skills remove <slug>
deeptutor skills login / publish ./my-skill / update
```

`deeptutor skill` 与 `deeptutor skills` 等价；其他 registry 用前缀，如 `clawhub:gh-release-notes`。（[with-deeptutor](https://eduhub.deeptutor.info/how-to-use/with-deeptutor)）

### 5.4 Web 侧接口（DeepTutor 的做法，可作为 Loop 的 API 蓝本）

DeepTutor 后端把 hub 代理成自家 API，前端不直连 EduHub（**实测** `deeptutor/api/routers/skills.py`、`web/lib/skills-api.ts`）：

| 自家端点 | 作用 |
|---|---|
| `GET /api/skills/list` | 已装 skill（`name/description/tags/source/read_only`） |
| `GET /api/skills/hub/catalog?hub=eduhub&q=&limit=` | 代理 hub 目录；返回 `{hub, web_url, skills[]}` |
| `GET /api/skills/hub/detail?slug=&hub=` | 代理详情 + SKILL.md 正文 |
| `POST /api/skills/install` | body `{ref, name?, force?, allow_unverified?}`；返回 `{skill:{name}, version, verdict:{status,detail}}` |
| `GET/POST/PUT/DELETE /api/skills/tags...` | 本地标签管理（与 hub 分类解耦） |

**这个设计值得照抄**：前端不直连外部 registry（避免 CORS、避免前端持有 token、避免 SSRF 面）；后端代理 + 归一化，`verdict` 直接回传给 UI 做警示。

---

## 6. 搜索 / 安装 / 更新 / 回滚 流程

### 6.1 推荐流程状态机

```
浏览 (catalog)  →  预览详情 (detail + verify)  →  用户勾选  →  下载  →  校验  →  落盘  →  记账
                                         │                                     │
                                         └── 裁决 suspicious/unknown ───────────┘
                                                （警告 / 需显式确认）
```

### 6.2 搜索

1. 关键词：`GET /api/v1/search?q=&limit=`
2. 按赛道：`GET /api/v1/search?q=&track=academics`
3. 无关键词浏览：`GET /api/v1/skills?limit=&sort=createdAt`
4. **领域/学段/形式筛选**：服务端不支持过滤（列表无这些字段）。建议 Loop 侧在本地做**增量富化缓存**——对已浏览过的 slug 缓存 `?files=true` 详情里的 `keywords`，并对详情逐个补 `track/language`（详情响应里同样没有，需靠搜索时的 `track` 参数或发布方约定）。**这是本次调研发现的生态短板，UI 上不要承诺"按领域精确筛选"。**

### 6.3 安装（推荐实现，对齐 DeepTutor 实测姿态）

```python
# 伪代码：Loop server 侧导入管线
1. 解析 ref: <hub>:[<owner>/]<slug>[@version]
2. verdict = GET /api/v1/skills/{slug}/verify?version|tag&ownerHandle
      ok=true       -> 继续
      ok=false      -> 默认拒绝；除非用户显式勾选"仍然安装"（UI 必须明示风险）
      请求失败      -> status="unknown"：安装但打警示标签
3. zip = GET /api/v1/download?slug=&version=|tag=&ownerHandle
4. 校验 zip：条目数 ≤ 600、单条 ≤ 4MB、总计 ≤ 40MB、压缩比 ≤ 阈值、拒绝绝对路径与 ".."
5. 解压到临时目录（流式，不落地权限位/符号链接）
6. 定位包根：根级 SKILL.md，否则单层子目录；多层/歧义 -> 拒绝
7. frontmatter 适配：name 强制为 slug；剥离 always；bins/env 折进 requires
8. 支持文件过后缀白名单 + 大小/数量上限；符号链接 -> 整体拒绝
9. 逐文件 sha256 与 verify 清单比对（新增，比 DeepTutor 更严）
10. 原子替换：写到 .install-<slug>.tmp -> 旧目录 rename 为 .<slug>.previous-<uuid> -> staging.rename(target)
11. 记账：.hub-lock.json 写 {hub, slug, ownerHandle, version, verdict, sha256, installedAt}
12. 清理临时目录；失败时回滚到 previous
```

> 第 9 步（sha256 比对）是**我们相对 DeepTutor 的增强**：它的 `fetch()` 拿到 zip 后直接解压，并不比对 `artifact.files[].sha256`。而本次实测已证明该清单完整可用（§3.6），加上它成本极低、收益明确。

### 6.4 更新

- 查询：`GET /api/v1/skills/{slug}` → `distTags.latest` 与本地记录版本比对。
- 注意官方语义：**`latest` 默认指向最高 semver**，但可以被 owner 移动（回退）。所以"有新版本"应判定为 `distTags.latest != 本地已装版本`，而不是简单的 semver 比较。
- 更新动作 = 重跑 §6.3 全流程（含 verify 与 sha256 校验），成功后写回记账。
- 尊重"用户锁定"：若用户 pin 了版本，跳过更新（CLI 的 `pinned` 字段就是这个意图，但没人写它——我们要自己实现）。

### 6.5 回滚

生态里存在**两层回滚**，语义完全不同：

| 层级 | 机制 | 谁能做 |
|---|---|---|
| Registry 侧（发布者回滚） | `POST /api/v1/skills/{slug}/dist-tags` 把 `latest` 指回旧版本（**不新建版本，只移动指针**）。npm 式语义：之后发布更高版本会把 `latest` 再次前移 | 仅 owner/管理员 |
| 本地侧（用户回滚） | 用 `--version <旧版本>` 重新安装；或直接用本地快照还原 | 用户自己 |

**Loop 必须实现本地回滚**（发布者回滚我们控制不了）：

- 方案 A（推荐）：安装时保留上一版目录快照，保留最近 N 版，UI 提供"回退到上一版"。
- 方案 B（轻量）：不保快照，回退 = 重新下载指定旧版本（需联网）。
- 两者都要有：**离线时用快照，在线时用指定版本**。
- 原子替换的失败保护已有明确定义与测试基线：DeepTutor 的 `test_install_rollback.py` 断言"替换失败时旧包与 origin 记账**逐字节保持原样**"（**实测**）。

### 6.6 离线与网络失败降级（**必须设计，不能只报错**）

| 场景 | 建议行为 |
|---|---|
| 完全离线 | 已装 skill 全部可用（它们是本地文档，本来就不需要网络）；浏览/安装入口置灰并给出"当前离线"提示 |
| 搜索超时 | 回退到本地已缓存目录快照（记住上次成功的 catalog），标注"数据可能过期" |
| verify 失败 | 按 DeepTutor 语义降级为 `unknown`：**允许安装但打警示**，不静默放行也不硬阻断 |
| 下载中断 | 丢弃临时目录，旧版本保持不动（原子替换保证） |
| 校验失败（sha256 不符） | **硬失败**，删除临时目录，明确报"包完整性校验不通过"。这是唯一必须硬失败的场景 |
| registry 不可达 | 支持 `EDUHUB_REGISTRY` 式可配置 base URL，便于自托管/镜像 |
| 超时/重试 | 列表/搜索 5–10s 超时；下载按大小放宽（40MB 上限）；重试 ≤ 2 次，指数退避；不做无限重试 |

> 关键原则：**skill 是纯文档，离线不影响已装 skill 的可用性**——这让降级设计要求很宽松，不要过度设计。

---

## 7. 来源与许可 & 安全边界

### 7.1 许可（license）

- frontmatter 与 `latestVersion` 都可带 `license` 字段（如 `MIT`、`CC-BY-4.0`）。
- 实测观察：官方发布的多个 skill 为 **`MIT-0`**（`socratic-tutor`、ClawHub 抽样均见 `MIT-0`）；也有 `null`（如 `learn-to-apply@1.0.2` 的 license 为空）。
- 生态惯例：复制/改编开源内容时附 **`ATTRIBUTION.md`**，写明原作者、项目名、许可、来源 URL、改了什么（[eduhub-skill-manager.md §2](https://eduhub.deeptutor.info/eduhub-skill-manager.md)）。实测中 `evidence-based-k12-math-lesson`、`learn-ai-architect` 都带 `ATTRIBUTION.md` + `LICENSE`。
- 官方 agent 指南明确要求："仅使用宽松许可的来源；保留署名；除非用户明确确认兼容性与授权，**不要**复制 GPL/AGPL 或无许可文本"（[eduhub-skill-manager.md §1](https://eduhub.deeptutor.info/eduhub-skill-manager.md)）。

**给 Loop 的落地要求**：
1. 安装/下载界面**必须显示 license**；缺失时显示"未声明许可"。
2. 落地时把 `LICENSE` / `ATTRIBUTION.md` **原样保留**在 skill 目录内，不要过滤掉（它们在 `?files=true` 清单里是 `application/octet-stream`，属于"无后缀文件"）。
3. 我们在 UI 上不承担法律判断，但必须**不隐藏**许可与来源信息。
4. 若未来做"教育 skills 站点聚合"，需要把"许可未知"的包单独标出。

### 7.2 来源可信度信号（实测，**要如实呈现，不能夸大**）

| 信号 | 实测值 | 含义 |
|---|---|---|
| `signature.status` | `unsigned`（全部样本） | 无包签名，不能做信任锚 |
| `security.confidence` | `low`（EduHub）/ `high`（ClawHub 某包） | 置信度本身不可靠 |
| `security.summary` | "Static scan found no high-signal malicious patterns. **Not a full malware scan.**" | 明确不是完整杀毒 |
| `virusTotal` / `skillSpector` / `dependencyRegistry` | `null` | EduHub 未接入 |
| `provenance.source` | `unavailable` | 无法追溯 GitHub 导入来源 |
| `owner.handle` / `owner.htmlUrl` | 可用 | 唯一的真实性线索：发布者身份（github/google 登录） |
| `stats.downloads` | 可用 | 弱信号，可作排序辅助（`socratic-tutor` 1015 次） |

**UI 建议**：把"static scan 通过（非完整杀毒）"作为中性信息展示，**不要**渲染成绿色盾牌之类的强安全承诺。

### 7.3 安全边界：**只允许 SKILL.md + 资源，禁止任意代码执行**

**威胁模型**：skill 包来自公网陌生人，经用户选择下载。攻击面包括：zip-slip 路径穿越、zip-bomb、符号链接越界、原生可执行文件落地、脚本被自动执行、`always:` 之类字段的提示词注入（让下载的 skill 强制注入每次对话）。

**规范侧声明的安全红线**（发布时静态扫描会拦，[skill-format.md §6](https://eduhub.deeptutor.info/skill-format.md)）：

- 原生可执行/安装包：`.exe .dll .so .dylib .bin .msi .dmg .pkg .app .bat .cmd .scr .com .jar .apk`
- 下载即执行：`curl … | bash`、`wget … | sh`、`curl … | python/node/perl/ruby`
- 反弹 shell：`/dev/tcp/…`、`nc -e`、`bash -i >& /dev/tcp/…`
- 毁灭性删除：`rm -rf /`、`rm -rf ~`
- 解码后执行：`base64 -d | sh`、`eval(atob(...))`、`exec(base64...)`
- 读取敏感凭据：`~/.ssh/id_rsa`、`~/.aws/credentials`、`.npmrc`、`.git-credentials`、`/etc/shadow`
- 挖矿：`stratum+tcp://`、`xmrig`、`minerd`
- 外带环境变量/密钥：`*_TOKEN/SECRET/KEY/PASSWORD`、`process.env.*` 发往远端
- PowerShell 编码命令 / IEX 远程执行

命中任一**高危**模式 → `verify` 裁决从 `pass` 翻成 `review` → **DeepTutor 的导入门会拒绝安装**（用户需显式 `--allow-unverified` 强装）。

> ⚠️ 但 Loop v0.8.0 **不应该依赖服务端扫描**：实测 `eduhub` CLI 根本不查 verify，而且扫描只覆盖"高危模式"，`scripts/academy_state.py` 这类正常脚本是**放行**的。安全责任在我们这一侧。

**Loop 侧必须实现的门（对齐 DeepTutor 实测姿态 + 我们的增强）**：

| # | 措施 | 依据 |
|---|---|---|
| 1 | 安装前必查 `verify`；`ok=false` 默认拒装，仅允许用户**显式**强装 | 实测 hub.py `install_from_hub` |
| 2 | zip 解压防滑：拒绝绝对路径与含 `..` 的段；解析后再做 `is_relative_to(root)` 二次校验 | 实测 `_extract_skill_zip` |
| 3 | zip 防炸：条目数 ≤ 600、单条 ≤ 4MB、总计 ≤ 40MB、压缩比上限、解压后大小不得超声明值（流式写入中检查） | 实测 `_extract_skill_zip` |
| 4 | **后缀白名单**（默认拒绝）：`""`（无后缀）.md .markdown .txt .rst .py .js .mjs .ts .sh .rb .lua .r .json .jsonl .yaml .yml .toml .ini .cfg .csv .tsv .html .htm .css .xml .sql .jinja .j2 .tmpl .template | 实测 `_IMPORT_ALLOWED_SUFFIXES` |
| 5 | 黑名单（发布侧用）：`.exe .dll .so .dylib .bin .msi .dmg .pkg .app .bat .cmd .scr .com .jar .apk` | 实测 `_DANGEROUS_BINARY_EXT` |
| 6 | **符号链接 → 整体拒绝**（链接可指向包外内容） | 实测 `_copy_support_tree` |
| 7 | 剥离 `always:`（防提示词注入到每次对话）；`name` 强制为 slug | 实测 `_compose_imported_frontmatter` |
| 8 | 用 `copyfile` 语义复制（**不保留 exec 权限位**） | 实测注释 "no permission bits (notably exec) survive the import" |
| 9 | 隐藏文件/目录静默忽略；`__MACOSX/` 忽略 | 实测 |
| 10 | 导入上限：单文件 ≤ 1,000,000 B、总计 ≤ 20,000,000 B、文件数 ≤ 500（**比 registry 更严**） | 实测 `_IMPORT_MAX_*` |
| 11 | 原子替换 + 失败回滚（保留旧包与记账） | 实测 `install_tree` + `test_install_rollback.py` |
| 12 | **本实现增强**：逐文件 sha256 与 verify 清单比对 | 本研究实测清单可用（§3.6） |
| 13 | **本实现增强**：skill 目录只作为**文本资料**参与检索/提示词拼接，**永不进入执行路径** | — |

**"禁止任意代码执行"的落地边界（建议写进 v0.8.0 验收）**：

- ✅ Loop **绝不 `exec`/`spawn`/`import`/`eval`** skill 目录内的任何文件。
- ✅ `.py`/`.sh` 等脚本文件按"**文本资源**"处理：可被检索、可被引用、可在 UI 中查看原文。
- ✅ 可选更严策略：v0.8.0 直接**不安装** `.py/.sh/.js/.rb/.lua/.r` 后缀（白名单收窄到纯文档 + 数据），把"脚本"推迟到有沙箱的版本。代价是丢失 `learn-ai-architect` 这类含脚本的包的部分内容——建议**安装但标记为"含脚本(未执行)"**，UI 明确提示。
- ✅ 落实"学科间数据库独立"：skill 落地路径必须**带 subject_id 作用域**，禁止跨学科共享目录（否则 A 学科装的东西会出现在 B 学科的检索里）。

### 7.4 前端注入面

- DeepTutor 的做法：前端**不直连** registry，走后端代理（`/api/skills/hub/catalog`、`/hub/detail`），并在源码里注明"网页导入流程总是构造 `eduhub:` ref，**使被伪造的 bridge 消息无法把安装重定向到其他 hub**"（实测 `routers/skills.py:60-64`）。
- **Loop 应照抄这一条**：安装请求的 hub 由后端白名单固定为 `eduhub`，不接受前端任意指定 registry URL（避免 SSRF 与重定向攻击）。自托管镜像通过服务端配置开启。

---

## 8. 用户自选安装 UX 建议（Loop 学科内）

设计目标（团队原文）：**UI 简洁高效，满足长期学习效率与持久性**。以下建议均落在"极简"上。

### 8.1 信息架构

```
学科 (Subject)
└── 学科设置 / 教学技能
    ├── 已安装（默认视图）        ← 进来先看到自己的，不是商店
    │   ├── 卡片：名称 · 版本 · 一句话描述 · 含脚本标记
    │   └── 操作：查看原文 / 检查更新 / 回退上一版 / 移除
    └── 从 EduHub 添加（一个按钮）
        └── 搜索框 + 结果列表（勾选式）→ 详情抽屉 → 安装
```

**核心原则：默认视图是"已安装"，不是"商城"。** 长期学习场景下，用户 95% 的时间只需要看到自己装了什么。

### 8.2 关键交互决策

| 场景 | 建议 |
|---|---|
| 列表项展示 | 名称 + 版本 + 一句话 `summary` + 下载量（弱信号）。**不展示**许可/扫描细节，避免噪音 |
| 详情抽屉 | SKILL.md 正文可展开（用户有权知道 AI 会读到什么）；展示 `license`、发布者、更新日期、"在 EduHub 查看"外链 |
| 一键安装 | 点击即装，不做多步向导。安装是"下载一个文档"，不该有心理负担 |
| 裁决 `pass` | 正常安装，**不要**显示"安全"字样（避免虚假安全感） |
| 裁决 `unknown` | 装，但在卡片上留一个低调的"未验证"标记 + tooltip 说明原因（离线/接口失败） |
| 裁决 `suspicious` | **阻断**，弹确认框：说明"EduHub 标记该包可疑"，需要用户勾选"我了解风险"才能继续 |
| 含脚本文件 | 卡片上标"含脚本(未执行)"，tooltip 说明"Loop 不会运行这些脚本" |
| 更新 | **不自动更新**。在卡片上显示"有新版本"点状提示，由用户点击 |
| 版本锁定 | 提供"锁定当前版本"开关（对齐 CLI 的 `pinned` 语义），锁定后不提示更新 |
| 回退 | 卡片操作菜单里的"回退到上一版"，一步完成，无需选版本号 |
| 移除 | 二次确认（学科内 skill 可能被对话引用） |
| 学科绑定 | 安装时默认绑定当前学科；提供"用于全部学科"选项（对应 `domains` 为空的通用 skill） |
| 离线态 | 搜索/安装按钮置灰 + "当前离线，已安装技能仍可使用"。**不要**弹错误对话框 |
| 空状态 | 不要放"商城欢迎页"。一句话 + "从 EduHub 添加"按钮即可 |

### 8.3 与学科数据模型的衔接（建议，实现时由架构组确认）

- `skill` 装到 `data/subjects/<subject_id>/skills/<slug>/`，记账写在 `<subject_id>/skills/.hub-lock.json`。
- 学科检索（RAG）索引时把 SKILL.md 与 `references/*.md` 作为**该学科的高优先素材**纳入（呼应"学科专属资料库与优先检索"）。
- `SKILL.md` 的 `description` 是唯一进系统提示词的字段（对应 DeepTutor 的 manifest 行渲染），**正文按需读取**——这与 DeepSeek Harness 自身的 skill 机制一致，可复用既有 `read_skill` 式工具。

---

## 9. 可验证的样例 skill 结构

下面这个包**已用真实的 `eduhub` CLI v0.1.7 跑通 `--dry-run`**（不是纸面设计）。

### 9.1 目录树

```text
loop-subject-tutor/
├── SKILL.md                       # 必需，根级，1165 B
├── references/
│   └── retrieval-policy.md        # 95 B
└── examples/
    └── sample-session.md          # 124 B
```

### 9.2 `SKILL.md`

```markdown
---
name: loop-subject-tutor
description: Tutor a learner inside one Loop subject using that subject's own materials. Use when the learner asks to be taught, drilled, or quizzed on a topic and a subject library is available.
track: academics
language: zh
domains: [stem, 数据结构]
stages: [university]
forms: [tutor, practice]
version: 1.0.0
license: MIT
---

# Loop 学科助教

在**单个学科**内讲解、陪练与批改，优先引用该学科资料库中的材料。

## 工作循环
1. 先判断问题属于哪个学科；不属于当前学科时提示用户切换。
2. 先检索学科资料库，命中则引用原文出处（文件名 + 小节）。
3. 未命中时明确说明"资料库中没有"，再给通用讲解。
4. 每轮结束给一个 1-2 分钟的微练习，并记录学习进度。

## 规则
- 不把 A 学科的资料用在 B 学科上。
- 引用资料时给出文件名，便于用户核对。
- 涉及考试压力时切换到直接讲解，不用苏格拉底式追问阻塞用户。

## 支持文件
- `references/retrieval-policy.md`：检索与引用规则细则。
- `examples/sample-session.md`：一次完整会话示例。
```

### 9.3 验证记录（实测输出）

```console
$ node <eduhub-0.1.7>/bin/eduhub.mjs --no-input skill publish ./loop-subject-tutor \
      --dry-run --track academics --language zh
📦 Dry run — would publish:
   slug:     loop-subject-tutor
   name:     loop-subject-tutor
   version:  1.0.0
   track:    academics
   language: zh
   files:    3
   zip size: 1.4 KB
EXIT=0
```

同一命令在 `--language ja` 下被拒绝：

```console
$ node <eduhub-0.1.7>/bin/eduhub.mjs --no-input skill publish ./loop-subject-tutor \
      --dry-run --track academics --language ja
❌ language must be one of: zh / en
EXIT=1
```

**结论**：该样例结构合规；同时实证了 §3.4 记录的 CLI 语言词表不一致问题。

### 9.4 复核清单（任何人可照做）

对任意待发布的 skill 目录，逐一确认：

| 检查项 | 期望 |
|---|---|
| `SKILL.md` 在根级、非空 | ✅ |
| frontmatter 有 `name` + `description`（description 含"做什么 + 何时用"） | ✅ |
| `track` ∈ {academics, companions, skills-interests, educators} | ✅ |
| `language` ∈ {zh, en}（**以 CLI 校验为准**，不是文档的开放词表） | ✅ |
| `version` 是合法 semver | ✅ |
| 文件数 ≤ 600、单文件 ≤ 4MB、总计 ≤ 40MB | ✅ |
| 无危险后缀（`.exe .dll …`）、无 dotfiles、无 `__MACOSX/` | ✅ |
| 相对路径引用支持文件，且文件确实存在 | ✅ |
| 无 `always:`（会被剥离，写了也没用） | ✅ |
| `eduhub … publish --dry-run` exit 0 | ✅ |
| （可选）发布后 `GET /api/v1/skills/{slug}?files=true` 的 sha256 清单与你本地逐文件 sha256 一致 | ✅ |

---

## 10. 可借鉴项目

| 项目 | 相关度 | 可借鉴 |
|---|---|---|
| [HKUDS/DeepTutor](https://github.com/HKUDS/DeepTutor) | ★★★★★ | **主要参考**。Apache-2.0。`deeptutor/services/skill/hub.py`（导入门）、`service.py`（原子安装/后缀白名单/记账）、`api/routers/skills.py`（代理式 API）、`cli/skill.py`、`web/components/space/EduHubImportModal.tsx`（导入 UI）、`tests/services/skill/test_install_rollback.py`（回滚契约） |
| [openclaw/clawhub](https://github.com/openclaw/clawhub) | ★★★★ | MIT，TypeScript。ClawHub registry 实现，协议上游 |
| [openclaw/agent-skills](https://github.com/openclaw/agent-skills) | ★★★ | MIT。技能集合与组织方式 |
| [anthropics/skills](https://github.com/anthropics/skills) | ★★★ | Agent Skills 公共仓库，SKILL.md 惯例源头 |
| [GarethManning/education-agent-skills](https://github.com/GarethManning/education-agent-skills) | ★★★★ | **165 个循证教学 skill**（教育学、学习科学、课程、评估），教师/学校场景。教学类 skill 的**内容参考库** |
| [koukekoukej-glitch/feynman-tutor](https://github.com/koukekoukej-glitch/feynman-tutor) | ★★★ | 费曼技巧教学 skill，单一职责设计的正面样本 |
| [lowwwbank/anything-to-course](https://github.com/lowwwbank/anything-to-course) | ★★ | "任意材料 → 自学课程"，含检索练习/间隔重复/tutor 模式，与学科学习进度设计呼应 |
| [mcxiaoxiao/kaoyan-navigator-skill](https://github.com/mcxiaoxiao/kaoyan-navigator-skill) | ★★ | 中文考研场景 skill，中文教学 skill 的措辞与结构参考 |
| [StudentSuite/awesome-skills-plugins-for-students](https://github.com/StudentSuite/awesome-skills-plugins-for-students) | ★★ | 面向学生的 skill/plugin 清单，用于发现内容 |

（star 数等元数据为 2026-10-25 实测）

---

## 11. 给 v0.8.0 的落地清单

**必须做（P0）**

- [ ] server 侧实现 §6.3 导入管线（verify → 下载 → 防滑/防炸 → 白名单 → sha256 → 原子替换 → 记账）
- [ ] 安全边界写进验收：无任何执行 skill 内文件的代码路径；符号链接拒绝；`always:` 剥离
- [ ] skill 落盘带 `subject_id` 作用域，学科间目录隔离
- [ ] 前端不直连 registry；hub 由后端白名单固定为 `eduhub`
- [ ] 离线降级：已装 skill 全部可用；搜索/安装优雅置灰
- [ ] UI：默认展示"已安装"，一键安装，不自动更新，提供回退

**应该做（P1）**

- [ ] 逐文件 sha256 校验（生态中唯一做这件事的）
- [ ] 本地版本快照 + 回退（离线可用）
- [ ] 用户锁定版本
- [ ] license / 发布者 / 更新日期展示；缺失时显式说明
- [ ] `unknown` vs `suspicious` 两档差异化处理

**明确不做（P2 / 本版本外）**

- [ ] 不实现 CLI 依赖（不 `npm i -g eduhub`）
- [ ] 不实现发布/登录/注销（v0.8.0 只需消费侧）
- [ ] 不支持任意 registry URL 由用户输入（SSRF 面）
- [ ] 不承诺"按领域/学段精确筛选"（registry 不提供该过滤能力）

---

## 12. 引用 URL 清单

**EduHub 官方**
- https://eduhub.deeptutor.info/skills
- https://eduhub.deeptutor.info/how-to-use/overview
- https://eduhub.deeptutor.info/how-to-use/any-agent
- https://eduhub.deeptutor.info/how-to-use/with-deeptutor
- https://eduhub.deeptutor.info/how-to-use/deeptutor
- https://eduhub.deeptutor.info/how-to-use/prepare
- https://eduhub.deeptutor.info/how-to-use/publish
- https://eduhub.deeptutor.info/how-to-use/maintain
- https://eduhub.deeptutor.info/how-to-use/agent-publish
- https://eduhub.deeptutor.info/skill-format.md ← **权威格式规范（中文，写给 agent）**
- https://eduhub.deeptutor.info/eduhub-skill-manager.md ← agent 创建/发布工作流指南
- https://eduhub.deeptutor.info/upload

**EduHub API（实测）**
- https://eduhub.deeptutor.info/api/v1/skills
- https://eduhub.deeptutor.info/api/v1/skills/socratic-tutor?files=true
- https://eduhub.deeptutor.info/api/v1/skills/socratic-tutor/verify?tag=latest
- https://eduhub.deeptutor.info/api/v1/search?q=socratic
- https://eduhub.deeptutor.info/api/v1/download?slug=socratic-tutor&version=1.0.0
- https://eduhub.deeptutor.info/api/v1/taxonomy

**ClawHub**
- https://clawhub.ai
- https://clawhub.ai/api/v1/skills?limit=2
- https://clawhub.ai/api/v1/search?q=github&limit=3
- https://clawhub.ai/api/v1/skills/github/verify?ownerHandle=steipete
- https://clawhub.ai/api/v1/download?slug=github&ownerHandle=steipete
- https://docs.openclaw.ai/clawhub/ · /clawhub/cli · /clawhub/publishing · /clawhub/skill-format · /clawhub/api · /clawhub/http-api · /clawhub/how-it-works · /clawhub/security-audits （**正文本次未能抓取，仅见导航**）

**npm**
- https://registry.npmjs.org/eduhub （v0.1.7，维护者 zzhtx/bingxi）
- https://registry.npmjs.org/eduhub/-/eduhub-0.1.7.tgz

**GitHub（全部实测访问）**
- https://github.com/HKUDS/DeepTutor （Apache-2.0）
- https://api.github.com/repos/HKUDS/DeepTutor
- https://github.com/HKUDS/DeepTutor/blob/main/deeptutor/services/skill/hub.py
- https://github.com/HKUDS/DeepTutor/blob/main/deeptutor/services/skill/service.py
- https://github.com/HKUDS/DeepTutor/blob/main/deeptutor/api/routers/skills.py
- https://github.com/HKUDS/DeepTutor/blob/main/web/lib/skills-api.ts
- https://github.com/HKUDS/DeepTutor/blob/main/tests/services/skill/test_install_rollback.py
- https://github.com/HKUDS/DeepTutor/blob/main/tests/services/skill/test_skill_hub.py
- https://github.com/HKUDS/DeepTutor/issues/78
- https://github.com/openclaw/clawhub
- https://github.com/openclaw/agent-skills
- https://github.com/anthropics/skills
- https://github.com/GarethManning/education-agent-skills
- https://github.com/koukekoukej-glitch/feynman-tutor
- https://github.com/lowwwbank/anything-to-course
- https://github.com/mcxiaoxiao/kaoyan-navigator-skill
- https://github.com/StudentSuite/awesome-skills-plugins-for-students

**社区**
- https://discord.gg/eRsjPgMU4t （DeepTutor Discord）
- https://community.openclaw.ai/

---

## 13. 复现命令

```powershell
# 1) 目录列表 / 规模
Invoke-RestMethod 'https://eduhub.deeptutor.info/api/v1/skills?limit=200'

# 2) 搜索（含 track 过滤）
Invoke-RestMethod 'https://eduhub.deeptutor.info/api/v1/search?q=tutor&limit=25&track=academics'

# 3) 详情 + sha256 清单
Invoke-RestMethod 'https://eduhub.deeptutor.info/api/v1/skills/learn-ai-architect?files=true'

# 4) 安全裁决
Invoke-RestMethod 'https://eduhub.deeptutor.info/api/v1/skills/socratic-tutor/verify?tag=latest'

# 5) 下载 + 逐文件 sha256 校验
$zip = "$env:TEMP\s.zip"
Invoke-WebRequest 'https://eduhub.deeptutor.info/api/v1/download?slug=socratic-tutor&version=1.0.0' -OutFile $zip
Get-FileHash $zip -Algorithm SHA256   # 期望 DCA541FBF67B48F14BC0B36F4E6D5C38ECC3634E323E5867E6394A8A071675F2

# 6) 分类词表
Invoke-RestMethod 'https://eduhub.deeptutor.info/api/v1/taxonomy'
```

---

*本文档随生态演进需复核；规范以 https://eduhub.deeptutor.info/skill-format.md 原始链接为准。*