# search-router skill 草案

## 触发场景

当用户需要搜索资料、查论文、查官方文档、查标准、查漏洞、查包元数据、查模型或需要多源交叉验证时，优先使用 `quality-search-gateway`。

## 路由规则

- 最新论文、arXiv 分类论文：优先 `latest_papers`，按需指定 `category=cs.AI/cs.LG/cs.CL`。
- 论文、预印本、研究趋势：优先 `search_sources`，`source_type=academic`。
- DOI、论文出处、出版元数据：优先 `search_sources`，`source_type=academic`。
- Python 语言设计：优先 `search_sources`，`source_type=standards`。
- 网络协议、RFC、草案：优先 `search_sources`，`source_type=standards`。
- Web API、兼容性、浏览器支持：优先 `search_sources`，`source_type=standards`。
- 漏洞、CVE、开源包安全：优先 `search_sources`，`source_type=security`。
- Python/npm 包版本和元数据：优先 `search_sources`，`source_type=packages`。
- GitHub 仓库、Issue、PR、Release：优先 `search_sources`，`source_type=code`。
- 模型、数据集、Spaces：优先 `search_sources`，`source_type=models`。
- 中文资料、国内软件、普通教程：使用 `search` 自动路由。
- 需要网页正文时：使用 `search_and_fetch` 或 `fetch_url`。
- 重要结论需要交叉验证时：使用 `compare_sources`。

## 约束

- 不要求工具保存长期索引。
- 不把结果写入知识库。
- 优先引用权威源 API 的结果。
- 免费后端优先，API key 后端只作为增强。
