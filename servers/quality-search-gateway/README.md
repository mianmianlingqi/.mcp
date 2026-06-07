# quality-search-gateway

`quality-search-gateway` 是一个轻量 MCP 服务器，用于把 Web 搜索和权威源 API 统一成少量高质量搜索工具。

本项目不做知识库、不做 RAG 入库、不保存长期索引。每次请求只在当前调用中完成搜索、抽取、合并和引用。

## 已实现后端

- 论文：arXiv、Semantic Scholar、OpenAlex、Crossref
- 标准/工程：Python PEPs、IETF Datatracker、MDN 搜索
- 安全：OSV
- 包生态：PyPI、npm Registry
- 代码/模型：GitHub Search API、Hugging Face Hub API
- Web 搜索/抽取：Exa、Firecrawl、open-webSearch 以可选后端形式接入；未配置 key 或服务不可用时会返回清晰降级信息

## MCP 工具

- `search(query, intent, language, freshness)`：自动路由到权威源 API 或 Web 后端。
- `search_sources(query, source_type)`：专查论文、标准、包生态、安全、代码、模型等源头库。
- `search_and_fetch(query, intent, max_pages)`：先搜索再抓取候选页面正文。
- `fetch_url(url)`：抓取单个 URL 正文。
- `compare_sources(query)`：调用至少两个来源并合并去重。

## 运行

```powershell
python .\quality-search-gateway\server.py --stdio
```

命令行自测：

```powershell
python .\quality-search-gateway\server.py --self-test
python .\quality-search-gateway\server.py --query "RAG evaluation benchmark recent papers" --intent academic
```

## 可选环境变量

- `EXA_API_KEY`：启用 Exa 搜索。
- `FIRECRAWL_API_KEY`：启用 Firecrawl 抓取。
- `GITHUB_TOKEN`：提高 GitHub API 额度。
- `SEMANTIC_SCHOLAR_API_KEY`：提高 Semantic Scholar API 额度。

未配置这些环境变量时，服务器仍可使用免费开放源：arXiv、OpenAlex、Crossref、PEPs、IETF、MDN、OSV、PyPI、npm、Hugging Face 等。

## Codex MCP 配置示例

```toml
[mcp_servers.quality_search_gateway]
command = "python"
args = ["C:\\Users\\35928\\Documents\\Codex\\2026-06-07\\mcp-skill-agent\\quality-search-gateway\\server.py", "--stdio"]
```
