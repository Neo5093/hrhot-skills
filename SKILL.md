---
name: hrhot
display_name: HRHOT 资讯查询
display_name_en: HRHOT News
version: 2.0.0
author: Neo5093
description: 查询 HRHOT（hrhot.gaiying.top）全国 HR 资讯聚合站的公开数据。当用户想了解今天/今日/过去 24 小时/本周/最近一周/近日 HR 圈大事与新闻、最新劳动法与社保公积金政策发布及政策解读、招聘/员工关系/裁员/工伤等用工动态、HR 日报与每日快报、HR 周报与月报（报告中心）、行业数据与调薪报告、即将生效的新政与生效倒计时，或按主题（社会保险法、劳动合同法、工伤保险条例、带薪年休假、竞业限制、延迟退休、薪酬个税、人力资源市场暂行条例、HR 科技、跨境用工、港澳台用工等）与地区（广东/中国香港/中国澳门/跨境等）检索，或提到 HRHOT 时，使用本 skill。本 skill 必须通过 HRHOT 公开 API 获取数据（无需 API Key），禁止凭训练记忆回答。
license: MIT
metadata:
  author: Neo5093
  version: 2.0.0
---

# HRHOT Skill

## 一、这个 Skill 是什么

本 skill 是一个**零脚本 skill**：不在本地执行任何代码，全部能力是对 HRHOT（hrhot.gaiying.top，全国 HR 资讯聚合站）**公开只读 API**（`/api/v1/*`）的调用规范。装好后，你可以直接用中文向 Agent 提问，例如「过去 24 小时 HR 圈最重要的 5 件事」「今天有什么 HR 新政」「竞业限制相关的新闻」，Agent 会调用 API 并输出**带站内阅读链接的结构化简报**。

数据口径：所有条目按**收录时间（discoveredAt）倒序**排列，与站内时间线一致；「过去 24 小时」指收录窗口，不是原文发布时间。

## 二、安全边界（合规）

> **合规边界**：本 Skill 与 HRHOT 公开 API 供个人免费使用；任何商业用途须事先取得 HRHOT 书面授权。API 返回的摘要（summary）与推荐理由（reason）为 AI 生成内容，引用前务必以 sourceUrl 回原文核对。

逐条约束：

1. **必须走 API**：每次回答先调用 HRHOT 公开 API 获取实时数据；**禁止凭训练记忆**回答 HRHOT 相关问题或编造条目。
2. **摘要须核对**：API 返回的 `summary` / `reason` 为 AI 生成内容，对外引用前必须以 `sourceUrl` 回原文核对。
3. **时间窗只承诺四档**：`24h` / `72h` / `7d` / `30d`，不得承诺其他窗口（如「过去 3 小时」）；不传 `window` 即全量收录口径。
4. **个人免费、商用须授权**：见上方合规边界，逐字转述给终端用户，不得删改语义。
5. **不批量转载 fullText**：`fullText` 仅限必要引用，且仅国家机关文件有；不得大段输出或整篇转载。
6. **频率礼仪**：单次提问最多发起约 5 个 API 请求；遇 429 按 `Retry-After` 退避（详见 references/errors.md）。

## 三、意图路由表（核心资产）

**每个意图只允许一个默认端点**，不得临时更换端点绕行；参数拼错时的重试路径见 references/errors.md。

| # | 用户意图（示例问法） | 默认端点 | 关键参数 | 输出要点 |
| --- | --- | --- | --- | --- |
| 1 | 「过去 24 小时 HR 圈最重要的 5 件事」「今天 HR 有什么大事」「今天有什么新鲜事」 | `/api/v1/items` | `mode=selected&window=24h&publishedWithin=7d&limit=5` | 5 条简报（标题+一句话+来源+评分+链接） |
| 2 | 「本周 HR 大事」「最近一周汇总」 | `/api/v1/items` | `mode=selected&window=7d&limit=10` | 按 category 分组的 10 条 |
| 3 | 24h 精选不足 3 条时的降级 | `/api/v1/items` | `mode=selected&window=7d&publishedWithin=7d&limit=5` | **必须显式说明实际时间窗是 7 天**，不得冒充 24h |
| 4 | 「今天的 HR 日报」 | `/api/v1/dailies/{今天}` | `date=YYYY-MM-DD`（Asia/Shanghai） | 导语 + 各分区 + flashes |
| 5 | 「最近有哪些日报」 | `/api/v1/dailies` | `limit=7` | 日期 + 收录/精选统计 |
| 6 | 「竞业限制 / 社保基数 / 延迟退休相关的新闻」 | `/api/v1/items` | `mode=all&tag=<受控词表规范词>`；查无结果降级 `mode=all&q=<词>` | 主题时间线（按日期分组） |
| 7 | 「政策法规发布类有什么新动态」 | `/api/v1/items` | `mode=selected&category=政策法规发布` | 分类列表 |
| 8 | 「广东 / 中国香港 / 跨境 有什么 HR 新政」 | `/api/v1/items` | `mode=selected&region=<地区>` | 地区列表 |
| 9 | 「搜一下 HR 科技 相关」 | `/api/v1/items` | `mode=all&q=HR科技` | 搜索结果 |
| 10 | 「最近有什么政策要生效」「生效倒计时」 | `/api/v1/countdown` | — | daysUntil 升序，标注剩余天数 |
| 11 | 「这条的详情 / 原文」 | `/api/v1/items/{id}` | — | 摘要 + fullText（如有）+ 原文链接 |
| 12 | 「现在有什么热门主题」 | `/api/v1/tags` | — | count/selectedCount 降序 Top N |
| 13 | 「本周有哪些 HR 政策？」「本周 HR 要闻回顾」 | `/api/v1/reports` | `kind=weekly` | 当期周报（lead 综述 + 分区 + 统计）；跨多期先取列表再按期次取详情 |
| 14 | 「给我看上月 HR 月报」「上个月盘点」 | `/api/v1/reports` | `kind=monthly` → `/api/v1/reports/{key}` | 先列表定位目标期次（periodStart/periodEnd），再取该期详情 |
| 15 | 「现在 HR 圈的热点事件？」「最近大家在讨论什么」 | `/api/v1/hot-topics` | — | 热点榜 Top 10（rank/heat 降序 + badges 状态徽标），每条带 `links.hrhot` 站内事件页 |

Base URL 统一为 `https://hrhot.gaiying.top/api/v1`；端点参数、字段语义与错误处理详见 `references/api.md` 与 `references/errors.md`。

**报告端点提示**：#13 / #14 走 `GET /api/v1/reports`（周报/月报，详见 `references/api.md` 第 7 节）。`lead` 为 AI 生成综述，引用前必须回原文核对。

**受控词表提示**：`tag` 必须使用受控词表规范词（如「社会保险法」「劳动合同法」「工伤保险条例」「带薪年休假」「人力资源市场暂行条例」）；可用 `/api/v1/tags` 发现热门主题的规范写法，不要自造同义词（如「五险一金」「劳动法」均非规范 tag，应走 `q` 搜索）。

**发布时间窗提示（V2.2.x）**：`publishedWithin=7d|30d|90d` 按**原文发布时间**（publishedAt）过滤，与 `window`（收录时间口径）正交、可组合；`publishedAt` 缺失的条目会被排除。「今天 / 新鲜事」类用例建议组合使用（如 `window=24h&publishedWithin=7d`），避免补录旧文（发布远早于收录）混入「今天」的答案。详见 `references/api.md` 第 3 节。

## 四、输出格式模板（Agent 须套用）

```markdown
## 过去 24 小时 HR 要闻（HRHOT 精选，数据截至 <discoveredAt 最大值>）

1. **<title>**（<sourceName> · AI 评分 <finalScore> · 收录于 <fmtDateTime(discoveredAt)>）
   <summary（AI 生成，引用前请以原文链接核对）>
   → 阅读：<links.hrhot> ｜ 原文：<sourceUrl>
2. …（共 5 条）

---
口径说明：以上为 HRHOT 过去 24 小时（按收录时间）精选条目；摘要由 AI 生成，引用前请回原文核对。
本数据供个人免费使用，商业用途须取得 HRHOT 书面授权。
```

模板纪律：每条引用**必须**带 `links.hrhot`（站内匿名可读阅读页）或 `sourceUrl`；时间戳一律换算为**北京时间（Asia/Shanghai）**展示；模板脚注（口径说明 + 合规声明）**每次输出都带**，不得省略。

## 五、防呆规则（MUST / NEVER）

**MUST**

- MUST 每次回答先调 API，禁止凭训练记忆回答 HRHOT 相关问题。
- MUST 每条引用带 `links.hrhot` 或 `sourceUrl`。
- MUST 简报注明数据口径（时间窗 + 「摘要为 AI 生成，引用前请核对原文」）。
- MUST 遵守 `Retry-After` 退避（实际由 CDN 缓存兜底，仍按头退避）。
- MUST 时间戳换算为北京时间展示。
- MUST 按路由表 #3 降级时显式声明实际时间窗。

**NEVER**

- NEVER 凭记忆编造 HRHOT 条目、标题或链接。
- NEVER 大段输出 fullText（仅限必要引用，且仅国家机关文件有）。
- NEVER 声称覆盖「全部」HR 资讯（口径 = HRHOT 已收录条目）。
- NEVER 承诺 24h/72h/7d/30d 之外的时间窗。
- NEVER 删除或弱化输出模板脚注中的合规声明。
