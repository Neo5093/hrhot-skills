# HRHOT 公开 API v1 完整合同

> 本文件是 HRHOT Skill 的数据源合同。所有端点均为**匿名只读**，无需 API Key，不读 Cookie。
> 本文档与 `https://hrhot.gaiying.top/api/v1` 线上行为保持一致；如有出入以线上为准并请反馈。

## 1. Base URL 与总约定

| 项 | 约定 |
| --- | --- |
| Base URL | `https://hrhot.gaiying.top/api/v1` |
| 鉴权 | 无。匿名只读，无需 API Key，不读 Cookie |
| CORS | 所有 v1 响应带 `Access-Control-Allow-Origin: *` |
| 方法 | 仅 GET（其他方法返回 405） |
| 响应体 | JSON；`schemaVersion: 2`（字段只增不改） |
| 时间 | ISO 8601 带时区（如 `2026-09-19T10:00:00.000Z`）；`window` 与日报日期口径 Asia/Shanghai |
| 排序 | `ordering: 'timelineDesc'`（按 discoveredAt 倒序，与站内时间线一致） |
| 分页 | 游标分页：回传 `page.nextCursor`；换查询条件（含 window）后复用旧 cursor 返回 `invalid_cursor` |
| 缓存 | 响应带 `Cache-Control: public, s-maxage=60, stale-while-revalidate=300` + 弱 ETag；请求带 `If-None-Match` 且匹配 → `304` |
| 限流 | MVP 期由 CDN 缓存抗量；如触发限流返回 `429` + `Retry-After` 头（见 errors.md） |
| 错误体 | `application/problem+json`，`type: https://hrhot.gaiying.top/problems/<type>` |

错误体示例：

```json
{
  "type": "https://hrhot.gaiying.top/problems/invalid-param",
  "title": "Invalid Parameter",
  "status": 400,
  "detail": "参数 window 非法：仅支持 24h / 72h / 7d / 30d"
}
```

## 2. 端点清单

| # | 方法 | 路径 | 用途 |
| --- | --- | --- | --- |
| 1 | GET | `/api/v1/items` | 条目列表：筛选 + 时间窗 + 游标分页 |
| 2 | GET | `/api/v1/items/{id}` | 条目详情 + 全文（仅国家机关文件有 fullText） |
| 3 | GET | `/api/v1/dailies` | 日报日期索引（新在前） |
| 4 | GET | `/api/v1/dailies/{date}` | 指定日期日报全文 |
| 5 | GET | `/api/v1/tags` | 主题标签聚合（热门主题发现） |
| 6 | GET | `/api/v1/countdown` | 即将生效的政策（生效日升序） |

## 3. `GET /api/v1/items`

### 查询参数

| 参数 | 类型 | 默认 | 约束 | 说明 |
| --- | --- | --- | --- | --- |
| `mode` | enum | `selected` | `selected` \| `all` | selected=仅精选；all=全部已收录 |
| `window` | enum | 无（不过滤） | `24h` \| `72h` \| `7d` \| `30d` | 按 `discoveredAt` 过滤：`discoveredAt >= now - window`。**「过去 24 小时」类问题的核心参数** |
| `category` | enum | 无 | 七分类之一（见第 7 节） | 非法值 400 `invalid-param` |
| `region` | string | 无 | 自由文本（现存值：全国 / 省名 / 中国香港 / 中国澳门 / 跨境） | 与站内一致，不做枚举校验 |
| `tag` | string | 无 | 1-40 字，大小写不敏感精确匹配 | 主题精确过滤，须用受控词表规范词 |
| `q` | string | 无 | 2-200 字 | 搜索标题/摘要/标签/来源名 |
| `limit` | int | 20 | 1-100 | 每页条数 |
| `cursor` | string | 无 | 上一页 `page.nextCursor` 原样回传 | 跨查询复用 → 400 `invalid-cursor` |

未知参数一律 400 `invalid-param`。

### 响应 200

```json
{
  "schemaVersion": 2,
  "query": {
    "mode": "selected",
    "window": "24h",
    "windowResolved": { "from": "2026-09-19T08:00:00.000Z", "to": "2026-09-20T08:00:00.000Z" },
    "category": null,
    "region": null,
    "tag": null,
    "q": null,
    "ordering": "timelineDesc"
  },
  "items": [
    {
      "id": "itm_xxx",
      "title": "……",
      "summary": "AI 一句话人话摘要（引用前须回原文核对）",
      "reason": null,
      "sourceName": "人力资源社会保障部",
      "sourceTier": "T1",
      "sourceUrl": "https://www.mohrss.gov.cn/……",
      "author": null,
      "publishedAt": "2026-09-19T09:12:00.000Z",
      "discoveredAt": "2026-09-19T10:00:00.000Z",
      "region": "全国",
      "category": "政策法规发布",
      "scores": { "impact": 9, "actionability": 8, "authority": 10, "urgency": 7, "novelty": 6 },
      "finalScore": 87,
      "isSelected": true,
      "effectiveDate": "2026-10-01",
      "policyName": null,
      "issuer": null,
      "hrFocus": null,
      "impacts": ["企业HR", "劳动者"],
      "tags": ["社会保险法"],
      "links": {
        "hrhot": "https://hrhot.gaiying.top/items/itm_xxx",
        "source": "https://www.mohrss.gov.cn/……"
      }
    }
  ],
  "page": { "count": 20, "hasMore": true, "nextCursor": "eyJ2IjoxLCJzaWciOi…" }
}
```

### 错误分支

| HTTP | type | 触发条件 |
| --- | --- | --- |
| 400 | `invalid-param` | mode/category/window/q/tag/limit 非法，或未知参数 |
| 400 | `invalid-cursor` | cursor 损坏或跨查询复用 |
| 429 | `rate-limited` | 平台限流触发（P2），带 `Retry-After` 头 |
| 500 | `internal` | 未捕获异常 |

## 4. `GET /api/v1/items/{id}`

- 入参：路径参数 `id`（如 `itm_xxx`）。
- 响应 200：`{ schemaVersion: 2, item: <HotItem + links，不含 fullTextPath>, fullText: string | null }`。
- `fullText` 经清洗（与站内详情页同出口）；**非国家机关文件为 `null`**。
- 404：`{ type: ".../not-found", title: "Not Found", status: 404, detail: "条目 <id> 不存在" }`。

## 5. `GET /api/v1/dailies` 与 `/api/v1/dailies/{date}`

### 索引 `GET /api/v1/dailies?limit=14`

`limit` 范围 1-60，默认 14。

```json
{
  "schemaVersion": 2,
  "count": 14,
  "items": [
    {
      "date": "2026-09-19",
      "stats": { "totalCollected": 42, "totalSelected": 9, "byCategory": { "政策法规发布": 3 } },
      "links": { "api": "/api/v1/dailies/2026-09-19" }
    }
  ]
}
```

### 日报 `GET /api/v1/dailies/2026-09-19`

- 响应 200：`{ schemaVersion: 2, report: <DailyReport> }`。
- `report` 结构：`date` / `generatedAt` / `lead`（导语）/ `sections[{category, items}]` / `flashes`（快讯）/ `stats`。
- `sections[].items` 与 `flashes` 中每个 item 均注入 `links.hrhot`（与 items 端点同构）。
- `date` 格式须 `YYYY-MM-DD`，否则 400 `invalid-param`；无日报 → 404 `not-found`。
- 日期口径为 Asia/Shanghai（「今天的日报」用北京时间当天日期）。

## 6. `GET /api/v1/tags` 与 `GET /api/v1/countdown`

### `/api/v1/tags`

与站内 `/api/tags` 同结构：

```json
{
  "schemaVersion": 2,
  "count": 200,
  "items": [
    { "tag": "社会保险法", "count": 42, "selectedCount": 9, "status": "formal", "group": "social-insurance" }
  ]
}
```

- 按 `count` 降序，上限 200。
- `status` / `group` 来自受控词表（formal / probation；词表外为 `null`）。
- 主题分组现存 5 组：`social-insurance`（社会保险与保障）、`labor-compliance`（劳动关系与合规）、`talent-comp`（人才与薪酬数据）、`hr-tech`（HR 科技与工具）、`cross-border`（港澳台与跨境）。

### `/api/v1/countdown`

```json
{
  "schemaVersion": 2,
  "count": 8,
  "items": [
    {
      "id": "itm_xxx",
      "title": "……",
      "category": "政策法规发布",
      "region": "全国",
      "sourceName": "人力资源社会保障部",
      "sourceUrl": "https://www.mohrss.gov.cn/……",
      "effectiveDate": "2026-10-01",
      "daysUntil": 11,
      "finalScore": 87,
      "links": {
        "hrhot": "https://hrhot.gaiying.top/items/itm_xxx",
        "source": "https://www.mohrss.gov.cn/……"
      }
    }
  ]
}
```

- `daysUntil >= 0`，按生效日升序（剩余天数少的在前）。

## 7. 七分类枚举与受控词表

**category 参数合法值（七分类）**：

1. `政策法规发布`
2. `政策解读与官方答疑`
3. `司法与裁审口径`
4. `数据与调薪报告`
5. `企业用工事件`
6. `HR科技与工具`
7. `港澳台与跨境用工`

**tag 受控词表**：`tag` 参数必须使用规范词，样例：`社会保险法`、`劳动合同法`、`工伤保险条例`、`带薪年休假`、`人力资源市场暂行条例`。获取完整热门规范词的方式：调用 `/api/v1/tags`，取 `items[].tag` 字段。用户口语词（如「五险一金」「劳动法」「退休」）**不要**直接作为 `tag`，应改用 `q` 搜索（`mode=all&q=<词>`）。

## 8. HotItem 字段全表

| 字段 | 类型 | 可空 | 含义 |
| --- | --- | --- | --- |
| `id` | string | 否 | 条目 ID（`itm_` 前缀） |
| `title` | string | 否 | 标题 |
| `summary` | string | 否 | AI 一句话人话摘要（**AI 生成，引用前须回原文核对**） |
| `reason` | string \| null | 是 | 入选精选的推荐理由（**AI 生成，引用前须回原文核对**；可直接用作简报中的推荐语） |
| `sourceName` | string | 否 | 来源名称（如「人力资源社会保障部」） |
| `sourceTier` | string | 否 | 来源分级（T1 国家机关 / T2 官方媒体 / T3 行业媒体） |
| `sourceUrl` | string | 否 | 原文链接 |
| `author` | string \| null | 是 | 作者 |
| `publishedAt` | string \| null | 是 | 原文发布时间（ISO 8601） |
| `discoveredAt` | string | 否 | 收录时间（ISO 8601），**时间线与 window 的口径** |
| `region` | string | 否 | 地区（全国 / 省名 / 中国香港 / 中国澳门 / 跨境） |
| `category` | string | 否 | 七分类之一 |
| `scores` | object | 否 | AI 评分：`impact`（影响力）/ `actionability`（可操作性）/ `authority`（权威性）/ `urgency`（紧迫性）/ `novelty`（新颖性），各 0-10 |
| `finalScore` | int | 否 | 综合分（0-100） |
| `isSelected` | bool | 否 | 是否精选 |
| `effectiveDate` | string \| null | 是 | 政策生效日（`YYYY-MM-DD`） |
| `policyName` | string \| null | 是 | 政策名称 |
| `issuer` | string \| null | 是 | 发布机关 |
| `hrFocus` | string \| null | 是 | HR 关注点 |
| `impacts` | string[] | 是 | 影响对象（如 `["企业HR", "劳动者"]`） |
| `tags` | string[] | 是 | 主题标签（受控词表规范词） |
| `links` | object | 否 | 链接对象，见第 9 节 |

注：公开 API **不输出**内部字段 `fullTextPath`；`fullText` 仅在 `/api/v1/items/{id}` 详情端点输出。

## 9. `links.hrhot` 约定

- `links.hrhot` = 条目在 HRHOT 站内的阅读页 URL（`https://hrhot.gaiying.top/items/<id>`），**匿名（未登录）可直接打开**。
- 所有对外输出的简报，每条引用**必须**带 `links.hrhot`（推荐同时附 `links.source` / `sourceUrl` 原文链接）。
- `links.source` 与 `sourceUrl` 等价，取其一即可。

## 10. 频率礼仪与 429 约定

- 单次用户提问最多发起约 5 个 API 请求；需要翻页时用 `page.nextCursor` 续拉，不要放大 `limit` 反复拉全量。
- 如收到 429：按 `Retry-After` 头退避后重试，最多累计等待 60 秒；仍失败则告知用户「HRHOT 服务暂时繁忙，请稍后再试」。
- 正常请求建议带 `Cache-Control` 语义由服务端 CDN 兜底（`s-maxage=60`），短时间内重复查询请复用已获取的结果，不要打重复请求。
