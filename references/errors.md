# HRHOT API 错误码 → Agent 行为分支

> 本文件规定 HRHOT 公开 API（`/api/v1/*`）各类错误与异常情况下，Agent 应采取的行为。
> 所有错误响应体均为 `application/problem+json`（RFC 7807）。

## 1. 错误响应体结构

```json
{
  "type": "https://hrhot.gaiying.top/problems/invalid-param",
  "title": "Invalid Parameter",
  "status": 400,
  "detail": "参数 window 非法：仅支持 24h / 72h / 7d / 30d"
}
```

- `type`：错误类型标识（取 URL 末段，如 `invalid-param`）。
- `status`：HTTP 状态码。
- `detail`：人类可读的具体原因，**优先按 detail 修正请求**。

## 2. 错误码分支表

| 情况 | HTTP / type | Agent 行为 |
| --- | --- | --- |
| 参数非法 | 400 `invalid-param` | 按 `detail` 修正参数后重试 **1 次**；仍失败则告知用户参数不合法，并列出合法值（如 window 仅支持 24h/72h/7d/30d，category 为七分类枚举，limit 为 1-100） |
| 游标失效 | 400 `invalid-cursor` | **丢弃 cursor**，从第一页重新请求；不得反复重试同一坏 cursor |
| 条目不存在 | 404 `not-found` | 告知用户该条目不存在；如链接来自早前对话，建议重新检索获取新链接 |
| 日报不存在 | 404 `not-found` | 建议改用 `GET /api/v1/dailies` 查询可用日期列表，再取其中一天 |
| 限流 | 429 `rate-limited` | 按响应头 `Retry-After`（秒）退避后重试，累计最多等待 60s；超时告知用户「HRHOT 服务暂时繁忙，请稍后再试」 |
| 服务端错误 | 500 `internal` | 同一查询原样重试 **1 次**；再失败明确告知「HRHOT 服务暂时不可用」，**禁止**用训练记忆内容冒充 API 结果 |
| 网络错误 / 超时 | — | 同上：重试 1 次，再失败告知服务不可用，禁止编造 |
| 方法不允许 | 405 | 本 API 仅支持 GET；检查是否误用了其他方法 |
| 空结果 | 200 但 `items` 为空 | 按 SKILL.md 路由表 #3 降级：`window=24h` 无内容时放宽到 `window=7d`（`mode=selected`），并**显式说明实际时间窗是 7 天**；`mode=selected` 为空时可降级 `mode=all`；`tag` 查无结果时降级 `q=<词>`。降级后仍须在输出中注明实际口径 |

## 3. Retry-After 退避策略

1. 收到 429 后读取 `Retry-After` 头（单位：秒）。
2. 等待该时长后重发**同一请求**（不要改参数）。
3. 每次重试都重新读取新的 `Retry-After`；累计等待超过 60 秒即停止，告知用户稍后再试。
4. 退避期间不要并发发起其他请求加压。

## 4. 降级路径速查

| 原始意图 | 首选 | 降级顺序 |
| --- | --- | --- |
| 过去 24 小时大事 | `mode=selected&window=24h&limit=5` | ① `mode=selected&window=7d&limit=5`（声明时间窗变化）→ ② `mode=all&window=7d` |
| 主题新闻 | `mode=all&tag=<规范词>` | ① `mode=all&q=<口语词>`（tag 查无结果时） |
| 今天的日报 | `/api/v1/dailies/{今天}` | ① `/api/v1/dailies?limit=7` 取最近日期 → 取其中一天 |
| 分类动态 | `mode=selected&category=<分类>` | ① 去掉 `category` 用 `mode=selected&window=7d` |

降级纪律：**每次降级都必须在输出中向用户说明实际使用的口径**（时间窗、模式、是否换了检索方式），不得让用户误以为得到的就是最初请求的结果。

## 5. 绝对禁止

- NEVER 在 API 失败（4xx/5xx/网络错误）时用训练记忆编造 HRHOT 条目、标题、评分或链接。
- NEVER 遇到 400 就反复原样重试而不看 `detail`。
- NEVER 忽略 429 的 `Retry-After` 头立即重试。
