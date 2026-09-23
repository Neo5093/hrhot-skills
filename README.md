# HRHOT Agent Skill

让 Claude Code / Codex 等 Agent 用中文查询 [HRHOT](https://hrhot.gaiying.top)（全国 HR 资讯聚合站）的公开数据：过去 24 小时 HR 要闻、新政发布、HR 日报、主题/地区检索、生效倒计时。

本 skill 是**零脚本 skill**：不在本地执行任何代码，全部能力是对 HRHOT 公开只读 API（`/api/v1/*`，匿名、无需 API Key）的调用规范。

## 效果示例

问你的 Agent：

> 过去 24 小时 HR 圈最重要的 5 件事

Agent 会调用 HRHOT 公开 API 并返回结构化中文简报：

```markdown
## 过去 24 小时 HR 要闻（HRHOT 精选，数据截至 2026-09-20 08:00）

1. **某某条例发布**（人力资源社会保障部 · AI 评分 87 · 收录于 2026-09-19 18:00）
   AI 一句话摘要（AI 生成，引用前请以原文链接核对）
   → 阅读：https://hrhot.gaiying.top/items/itm_xxx ｜ 原文：https://www.mohrss.gov.cn/……

---
口径说明：以上为 HRHOT 过去 24 小时（按收录时间）精选条目；摘要由 AI 生成，引用前请回原文核对。
本数据供个人免费使用，商业用途须取得 HRHOT 书面授权。
```

## 安装（三选一）

### 1. 提示词安装（推荐）

把下面这句话发给你的 Agent（Claude Code / Codex 等）：

```
请安装 HRHOT Skill：https://hrhot.gaiying.top/hrhot-skill/README.md
```

Agent 会自行读取本说明并完成安装。

### 2. curl 一键安装

```bash
curl -fsSL https://hrhot.gaiying.top/hrhot-skill/install.sh | bash -s -- --target claude
```

- 安装到 `~/.agents/skills/hrhot`，并在 `~/.claude/skills/hrhot` 建立软链（不复制第二份）。
- Windows 请使用 **Git Bash** 执行。
- 安装器会先下载 `manifest.sha256` 清单，按白名单逐文件下载并**即时校验 SHA-256**，校验通过后才原子替换目标目录；任何一步失败自动回滚，不留半成品。
- 更多选项：`install.sh --help`（支持 `--target agents|claude`、`--dir`、`--base`、`--migrate-legacy`、`--force`）。

### 3. git clone

```bash
git clone https://github.com/Neo5093/hrhot-skills.git ~/.agents/skills/hrhot
```

（Windows 用 Git Bash；克隆的是 GitHub 镜像，与站内托管副本字节一致。）

## 能做什么 / 不能做什么

**能**：

- 过去 24 小时 / 本周 HR 大事与精选要闻（带站内阅读链接）
- 最新劳动法、社保公积金、薪酬个税等政策发布与政策解读
- 招聘、员工关系、裁员、工伤等用工动态
- HR 日报（今日/历史）与每日快报
- 按主题（社保、劳动合同、工伤、竞业限制、跨境用工等）或地区检索
- 即将生效的新政与生效倒计时、热门主题发现

**不能**：

- 写操作、个性化、收藏（这些仍须登录 HRHOT 网站）
- 覆盖「全部」HR 资讯（数据口径 = HRHOT 已收录条目）
- 商用（见下方合规声明）
- 离线使用（必须实时调用 API，禁止 Agent 凭记忆回答）

## 目录结构

```text
hrhot-skills/
├── SKILL.md                # 核心资产：frontmatter + 安全边界 + 意图路由表 + 输出模板 + 防呆规则
├── README.md               # 本文件：人类说明与安装指引
├── LICENSE                 # MIT（仅覆盖本包文件）
├── install.sh              # 安装器：白名单 + SHA-256 验签 + 原子替换 + 软链 + 回滚
├── manifest.sha256         # 逐文件验签清单（install.sh 的验签源）
├── agents/
│   └── openai.yaml         # Codex 兼容声明
└── references/
    ├── api.md              # 公开 API v1 完整合同（端点/参数/字段/分页/时间口径）
    └── errors.md           # 错误码 → Agent 行为分支 + Retry-After 退避策略
```

## 数据来源与 API

所有数据来自 HRHOT 公开 API：`https://hrhot.gaiying.top/api/v1`（匿名只读，无需 API Key）。完整合同见 [references/api.md](references/api.md)，错误处理见 [references/errors.md](references/errors.md)。

## License 与合规声明

**License**：本仓库文件采用 MIT（仅覆盖 skill 包自身文件，**不覆盖 HRHOT 的数据内容**）。数据使用边界：个人免费使用；商业用途须事先取得书面授权（联系 Neo5093 或见 hrhot.gaiying.top）；AI 生成的摘要与推荐理由，引用前须回原文核对。

另：HRHOT 站内文章版权归各来源方所有，`links.source` / `sourceUrl` 为原文出处，引用请以原文为准。
