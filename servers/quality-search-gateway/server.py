#!/usr/bin/env python3
"""高质量搜索路由 MCP 服务器。

目标：
- 不做长期知识库，不保存索引。
- 免费开放 API 优先，API key 后端作为增强。
- 用标准库实现，降低部署成本。
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import textwrap
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Tuple


USER_AGENT = "quality-search-gateway/0.1 (+https://modelcontextprotocol.io)"
DEFAULT_TIMEOUT = 18
MAX_RESULTS = 5


class GatewayError(Exception):
    """可向用户展示的网关错误。"""


@dataclass
class SearchResult:
    title: str
    url: str
    source: str
    snippet: str = ""
    metadata: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "title": self.title,
            "url": self.url,
            "source": self.source,
            "summary": self.snippet,
            "metadata": self.metadata or {},
        }


def log(message: str) -> None:
    print(f"[quality-search-gateway] {message}", file=sys.stderr, flush=True)


def http_json(
    url: str,
    *,
    method: str = "GET",
    payload: Optional[Dict[str, Any]] = None,
    headers: Optional[Dict[str, str]] = None,
    timeout: int = DEFAULT_TIMEOUT,
) -> Any:
    body = None
    req_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if headers:
        req_headers.update(headers)
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        req_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            return json.loads(data.decode(charset, errors="replace"))
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")[:500]
        raise GatewayError(f"HTTP {exc.code}: {url} {text}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise GatewayError(f"请求失败：{url}，原因：{exc}") from exc


def http_text(
    url: str,
    *,
    headers: Optional[Dict[str, str]] = None,
    timeout: int = DEFAULT_TIMEOUT,
) -> str:
    req_headers = {"User-Agent": USER_AGENT, "Accept": "text/html,application/xml,text/plain,*/*"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read(2_000_000)
            charset = resp.headers.get_content_charset() or "utf-8"
            return data.decode(charset, errors="replace")
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")[:500]
        raise GatewayError(f"HTTP {exc.code}: {url} {text}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise GatewayError(f"请求失败：{url}，原因：{exc}") from exc


def strip_html(value: str) -> str:
    value = re.sub(r"(?is)<(script|style).*?>.*?</\1>", " ", value)
    value = re.sub(r"(?s)<[^>]+>", " ", value)
    value = html.unescape(value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


def summarize_text(text: str, limit: int = 1800) -> str:
    text = strip_html(text)
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0] + "..."


def normalize_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    query_pairs = [
        (k, v)
        for k, v in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if not k.lower().startswith("utm_")
    ]
    return urllib.parse.urlunsplit(
        (
            parsed.scheme.lower(),
            parsed.netloc.lower(),
            parsed.path.rstrip("/") or "/",
            urllib.parse.urlencode(query_pairs),
            "",
        )
    )


def dedupe(results: Iterable[SearchResult]) -> List[SearchResult]:
    seen = set()
    out: List[SearchResult] = []
    for item in results:
        key = normalize_url(item.url) if item.url else f"{item.source}:{item.title}"
        doi = (item.metadata or {}).get("doi")
        arxiv_id = (item.metadata or {}).get("arxiv_id")
        package = (item.metadata or {}).get("package")
        if doi:
            key = f"doi:{str(doi).lower()}"
        elif arxiv_id:
            key = f"arxiv:{str(arxiv_id).lower()}"
        elif package:
            key = f"pkg:{item.source}:{str(package).lower()}"
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def infer_source_type(query: str, intent: str = "", language: str = "") -> str:
    q = f"{query} {intent} {language}".lower()
    if any(token in q for token in ["paper", "arxiv", "doi", "论文", "研究", "benchmark", "evaluation"]):
        return "academic"
    if any(token in q for token in ["pep", "python proposal", "rfc", "ietf", "mdn", "browser compatibility", "标准"]):
        return "standards"
    if any(token in q for token in ["cve", "vulnerability", "osv", "漏洞", "prototype pollution"]):
        return "security"
    if any(token in q for token in ["pypi", "npm", "package", "metadata", "版本", "依赖"]):
        return "packages"
    if any(token in q for token in ["github", "repository", "issue", "pull request", "repo"]):
        return "code"
    if any(token in q for token in ["hugging face", "model", "dataset", "embedding", "spaces"]):
        return "models"
    if any("\u4e00" <= ch <= "\u9fff" for ch in q):
        return "web_cn"
    return "web"


def wants_latest(value: str = "") -> bool:
    q = value.lower()
    return any(token in q for token in ["latest", "recent", "new", "newest", "fresh", "最新", "近期", "最近"])


def arxiv_search_query(query: str) -> str:
    q = query.lower()
    if any(token in q for token in ["cs.ai", "artificial intelligence", "人工智能"]) or re.search(r"\bai\b", q):
        return "cat:cs.AI"
    return f"all:{query}"


def search_arxiv(query: str, max_results: int = MAX_RESULTS, freshness: str = "") -> List[SearchResult]:
    latest = wants_latest(f"{query} {freshness}")
    params = urllib.parse.urlencode(
        {
            "search_query": arxiv_search_query(query),
            "start": 0,
            "max_results": max_results,
            "sortBy": "submittedDate" if latest else "relevance",
            "sortOrder": "descending",
        }
    )
    xml_text = http_text(f"https://export.arxiv.org/api/query?{params}", timeout=DEFAULT_TIMEOUT)
    root = ET.fromstring(xml_text)
    ns = {"atom": "http://www.w3.org/2005/Atom", "arxiv": "http://arxiv.org/schemas/atom"}
    results: List[SearchResult] = []
    for entry in root.findall("atom:entry", ns):
        title = (entry.findtext("atom:title", default="", namespaces=ns) or "").strip()
        summary = (entry.findtext("atom:summary", default="", namespaces=ns) or "").strip()
        entry_id = entry.findtext("atom:id", default="", namespaces=ns) or ""
        arxiv_id = entry_id.rsplit("/", 1)[-1]
        pdf_url = ""
        for link in entry.findall("atom:link", ns):
            if link.attrib.get("title") == "pdf":
                pdf_url = link.attrib.get("href", "")
        authors = [a.findtext("atom:name", default="", namespaces=ns) for a in entry.findall("atom:author", ns)]
        results.append(
            SearchResult(
                title=re.sub(r"\s+", " ", title),
                url=entry_id,
                source="arXiv",
                snippet=summarize_text(summary, 500),
                metadata={
                    "arxiv_id": arxiv_id,
                    "pdf_url": pdf_url,
                    "published": entry.findtext("atom:published", default="", namespaces=ns),
                    "updated": entry.findtext("atom:updated", default="", namespaces=ns),
                    "authors": [a for a in authors if a],
                    "categories": [
                        c.attrib.get("term")
                        for c in entry.findall("atom:category", ns)
                        if c.attrib.get("term")
                    ],
                },
            )
        )
    return results


def search_semantic_scholar(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    fields = "title,url,abstract,year,authors,citationCount,externalIds,venue"
    params = urllib.parse.urlencode({"query": query, "limit": max_results, "fields": fields})
    headers = {}
    api_key = os.getenv("SEMANTIC_SCHOLAR_API_KEY")
    if api_key:
        headers["x-api-key"] = api_key
    data = http_json(f"https://api.semanticscholar.org/graph/v1/paper/search?{params}", headers=headers)
    results: List[SearchResult] = []
    for paper in data.get("data", []):
        external = paper.get("externalIds") or {}
        url = paper.get("url") or (f"https://doi.org/{external.get('DOI')}" if external.get("DOI") else "")
        results.append(
            SearchResult(
                title=paper.get("title") or "未命名论文",
                url=url,
                source="Semantic Scholar",
                snippet=summarize_text(paper.get("abstract") or "", 500),
                metadata={
                    "year": paper.get("year"),
                    "venue": paper.get("venue"),
                    "citation_count": paper.get("citationCount"),
                    "doi": external.get("DOI"),
                    "arxiv_id": external.get("ArXiv"),
                    "authors": [a.get("name") for a in paper.get("authors", []) if a.get("name")],
                },
            )
        )
    return results


def search_openalex(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    params = urllib.parse.urlencode({"search": query, "per-page": max_results})
    data = http_json(f"https://api.openalex.org/works?{params}")
    results: List[SearchResult] = []
    for work in data.get("results", []):
        doi = work.get("doi")
        results.append(
            SearchResult(
                title=work.get("display_name") or "未命名作品",
                url=doi or work.get("id") or "",
                source="OpenAlex",
                snippet=summarize_text(work.get("abstract_inverted_index") and inverted_abstract(work), 500),
                metadata={
                    "doi": doi.replace("https://doi.org/", "") if isinstance(doi, str) else doi,
                    "year": work.get("publication_year"),
                    "cited_by_count": work.get("cited_by_count"),
                    "type": work.get("type"),
                },
            )
        )
    return results


def inverted_abstract(work: Dict[str, Any]) -> str:
    inv = work.get("abstract_inverted_index") or {}
    tokens: List[Tuple[int, str]] = []
    for word, positions in inv.items():
        for pos in positions:
            tokens.append((int(pos), word))
    return " ".join(word for _, word in sorted(tokens))


def search_crossref(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    params = urllib.parse.urlencode({"query": query, "rows": max_results})
    data = http_json(f"https://api.crossref.org/works?{params}")
    items = data.get("message", {}).get("items", [])
    results: List[SearchResult] = []
    for item in items:
        title = " ".join(item.get("title") or []) or "未命名作品"
        doi = item.get("DOI")
        url = item.get("URL") or (f"https://doi.org/{doi}" if doi else "")
        results.append(
            SearchResult(
                title=title,
                url=url,
                source="Crossref",
                snippet=summarize_text(" ".join(item.get("container-title") or []), 300),
                metadata={
                    "doi": doi,
                    "publisher": item.get("publisher"),
                    "type": item.get("type"),
                    "published": item.get("published-print") or item.get("published-online"),
                },
            )
        )
    return results


def search_peps(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    data = http_json("https://peps.python.org/api/peps.json")
    query_tokens = meaningful_tokens(query)
    scored: List[Tuple[int, str, Dict[str, Any]]] = []
    for pep_id, pep in data.items():
        haystack = f"{pep_id} {pep.get('title', '')} {pep.get('authors', '')} {pep.get('topic', '')}".lower()
        score = sum(3 if token in str(pep.get("title", "")).lower() else 1 for token in query_tokens if token in haystack)
        if score:
            scored.append((score, pep_id, pep))
    scored.sort(key=lambda item: (-item[0], int(item[1]) if item[1].isdigit() else 99999))
    results: List[SearchResult] = [
        SearchResult(
            title=f"PEP {pep_id}: {pep.get('title', '')}",
            url=pep.get("url") or f"https://peps.python.org/pep-{int(pep_id):04d}/",
            source="Python PEPs",
            snippet=f"状态：{pep.get('status', '')}；类型：{pep.get('type', '')}",
            metadata={"pep": pep_id, "status": pep.get("status"), "type": pep.get("type"), "score": score},
        )
        for score, pep_id, pep in scored[:max_results]
    ]
    if not results:
        for pep_id, pep in list(data.items())[:max_results]:
            results.append(
                SearchResult(
                    title=f"PEP {pep_id}: {pep.get('title', '')}",
                    url=pep.get("url") or f"https://peps.python.org/pep-{int(pep_id):04d}/",
                    source="Python PEPs",
                    snippet="未命中精确关键词，返回索引候选。",
                    metadata={"pep": pep_id, "status": pep.get("status"), "type": pep.get("type")},
                )
            )
    return results


def meaningful_tokens(query: str) -> List[str]:
    stop = {
        "the",
        "a",
        "an",
        "and",
        "or",
        "for",
        "to",
        "of",
        "in",
        "on",
        "api",
        "docs",
        "doc",
        "official",
        "metadata",
        "latest",
        "python",
        "pep",
        "rfc",
        "query",
        "search",
    }
    return [token for token in re.findall(r"[a-z0-9]+", query.lower()) if token not in stop and len(token) > 1]


def search_ietf(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    direct = direct_rfc_results(query)
    if direct:
        return direct[:max_results]
    params = urllib.parse.urlencode({"name__contains": query, "limit": max_results})
    data = http_json(f"https://datatracker.ietf.org/api/v1/doc/document/?{params}")
    results: List[SearchResult] = []
    for item in data.get("objects", []):
        name = item.get("name") or ""
        results.append(
            SearchResult(
                title=f"{name}: {item.get('title') or ''}".strip(": "),
                url=f"https://datatracker.ietf.org/doc/{name}/",
                source="IETF Datatracker",
                snippet=item.get("abstract") or item.get("title") or "",
                metadata={"name": name, "type": item.get("type"), "state": item.get("states")},
            )
        )
    if results:
        return results
    # Datatracker 的 name 查询对自然语言不友好，降级到站内搜索页面。
    return [
        SearchResult(
            title=f"IETF Datatracker 搜索：{query}",
            url=f"https://datatracker.ietf.org/doc/search/?name={urllib.parse.quote(query)}",
            source="IETF Datatracker",
            snippet="未通过 API 命中文档名称，返回官方搜索入口。",
            metadata={"query": query},
        )
    ]


def direct_rfc_results(query: str) -> List[SearchResult]:
    q = query.lower().replace("-", "").replace(" ", "")
    results: List[SearchResult] = []
    explicit = re.findall(r"rfc\s*([0-9]{3,5})", query, flags=re.I)
    for number in explicit:
        results.append(rfc_result(number, f"RFC {number}"))
    if "http/3" in q or "http3" in q:
        results.append(rfc_result("9114", "RFC 9114: HTTP/3"))
    return results


def rfc_result(number: str, title: str) -> SearchResult:
    return SearchResult(
        title=title,
        url=f"https://www.rfc-editor.org/rfc/rfc{number}.html",
        source="IETF/RFC Editor",
        snippet="RFC Editor 官方文档入口。",
        metadata={"rfc": number, "datatracker_url": f"https://datatracker.ietf.org/doc/rfc{number}/"},
    )


def search_mdn(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    params = urllib.parse.urlencode({"q": query, "locale": "en-US"})
    data = http_json(f"https://developer.mozilla.org/api/v1/search?{params}")
    documents = data.get("documents") or data.get("results") or []
    results: List[SearchResult] = []
    for doc in documents[:max_results]:
        url = doc.get("mdn_url") or doc.get("url") or ""
        if url.startswith("/"):
            url = f"https://developer.mozilla.org{url}"
        results.append(
            SearchResult(
                title=doc.get("title") or doc.get("slug") or "MDN 文档",
                url=url,
                source="MDN",
                snippet=summarize_text(doc.get("summary") or doc.get("excerpt") or "", 400),
                metadata={"slug": doc.get("slug"), "locale": doc.get("locale")},
            )
        )
    return results


def search_osv(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    # OSV 没有通用全文搜索。按常见包名/生态做启发式查询。
    tokens = re.findall(r"[A-Za-z0-9_.@/-]+", query)
    candidates = []
    ecosystems = ["PyPI", "npm", "Go", "Maven", "crates.io"]
    for token in tokens[:4]:
        clean = token.strip("@,.;:")
        if len(clean) < 2:
            continue
        for eco in ecosystems:
            candidates.append((eco, clean))
    results: List[SearchResult] = []
    seen = set()
    for ecosystem, package in candidates:
        if len(results) >= max_results:
            break
        try:
            data = http_json(
                "https://api.osv.dev/v1/query",
                method="POST",
                payload={"package": {"name": package, "ecosystem": ecosystem}},
                timeout=10,
            )
        except GatewayError:
            continue
        for vuln in data.get("vulns", [])[: max_results - len(results)]:
            vid = vuln.get("id")
            if not vid or vid in seen:
                continue
            seen.add(vid)
            results.append(
                SearchResult(
                    title=f"{vid}: {vuln.get('summary') or package}",
                    url=f"https://osv.dev/vulnerability/{vid}",
                    source="OSV",
                    snippet=summarize_text(vuln.get("details") or vuln.get("summary") or "", 500),
                    metadata={"id": vid, "package": package, "ecosystem": ecosystem, "aliases": vuln.get("aliases", [])},
                )
            )
    if not results:
        results.append(
            SearchResult(
                title=f"OSV 未通过包名命中：{query}",
                url="https://osv.dev/",
                source="OSV",
                snippet="OSV API 偏包名/版本查询，不提供通用自然语言全文搜索。建议输入具体包名和生态。",
                metadata={"query": query},
            )
        )
    return results


def search_pypi(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    package = first_package_token(query)
    if not package:
        return []
    data = http_json(f"https://pypi.org/pypi/{urllib.parse.quote(package)}/json")
    info = data.get("info", {})
    version = info.get("version")
    return [
        SearchResult(
            title=f"PyPI: {info.get('name') or package} {version or ''}".strip(),
            url=info.get("project_url") or f"https://pypi.org/project/{package}/",
            source="PyPI",
            snippet=summarize_text(info.get("summary") or info.get("description") or "", 500),
            metadata={
                "package": info.get("name") or package,
                "version": version,
                "requires_python": info.get("requires_python"),
                "license": info.get("license"),
            },
        )
    ]


def search_npm(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    package = first_package_token(query, allow_scope=True)
    if not package:
        return []
    data = http_json(f"https://registry.npmjs.org/{urllib.parse.quote(package, safe='')}")
    latest = (data.get("dist-tags") or {}).get("latest")
    latest_data = (data.get("versions") or {}).get(latest, {}) if latest else {}
    return [
        SearchResult(
            title=f"npm: {data.get('name') or package} {latest or ''}".strip(),
            url=f"https://www.npmjs.com/package/{package}",
            source="npm",
            snippet=summarize_text(data.get("description") or latest_data.get("description") or "", 500),
            metadata={
                "package": data.get("name") or package,
                "version": latest,
                "license": latest_data.get("license"),
                "homepage": latest_data.get("homepage"),
            },
        )
    ]


def first_package_token(query: str, allow_scope: bool = False) -> str:
    pattern = r"@[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|[A-Za-z0-9_.-]+"
    stop = {
        "latest",
        "metadata",
        "package",
        "pypi",
        "npm",
        "version",
        "查询",
        "版本",
        "包",
    }
    for token in re.findall(pattern, query):
        if token.lower() in stop:
            continue
        if token.startswith("@") and not allow_scope:
            continue
        return token
    return ""


def search_github(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    params = urllib.parse.urlencode({"q": query, "per_page": max_results})
    headers = {}
    token = os.getenv("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = http_json(f"https://api.github.com/search/repositories?{params}", headers=headers)
    results: List[SearchResult] = []
    for item in data.get("items", []):
        results.append(
            SearchResult(
                title=item.get("full_name") or item.get("name") or "GitHub 仓库",
                url=item.get("html_url") or "",
                source="GitHub",
                snippet=summarize_text(item.get("description") or "", 400),
                metadata={
                    "stars": item.get("stargazers_count"),
                    "language": item.get("language"),
                    "updated_at": item.get("updated_at"),
                    "license": (item.get("license") or {}).get("spdx_id"),
                },
            )
        )
    return results


def search_huggingface(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    params = urllib.parse.urlencode({"search": query, "limit": max_results})
    data = http_json(f"https://huggingface.co/api/models?{params}")
    if not data:
        data = http_json(
            f"https://huggingface.co/api/models?{urllib.parse.urlencode({'filter': 'sentence-similarity', 'limit': max_results})}"
        )
    results: List[SearchResult] = []
    for item in data[:max_results]:
        model_id = item.get("modelId") or item.get("id") or "unknown"
        results.append(
            SearchResult(
                title=f"Hugging Face: {model_id}",
                url=f"https://huggingface.co/{model_id}",
                source="Hugging Face",
                snippet=", ".join(item.get("tags", [])[:8]),
                metadata={
                    "downloads": item.get("downloads"),
                    "likes": item.get("likes"),
                    "pipeline_tag": item.get("pipeline_tag"),
                    "library_name": item.get("library_name"),
                },
            )
        )
    return results


def search_exa(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    api_key = os.getenv("EXA_API_KEY")
    if not api_key:
        raise GatewayError("Exa 后端未启用：缺少 EXA_API_KEY。")
    data = http_json(
        "https://api.exa.ai/search",
        method="POST",
        payload={"query": query, "numResults": max_results},
        headers={"x-api-key": api_key},
    )
    results = []
    for item in data.get("results", []):
        results.append(
            SearchResult(
                title=item.get("title") or item.get("url") or "Exa 结果",
                url=item.get("url") or "",
                source="Exa",
                snippet=summarize_text(item.get("text") or item.get("summary") or "", 500),
                metadata={"published_date": item.get("publishedDate"), "score": item.get("score")},
            )
        )
    return results


def search_open_web(query: str, max_results: int = MAX_RESULTS) -> List[SearchResult]:
    # 不依赖外部 open-webSearch 服务时，使用 DuckDuckGo HTML 作为免 key 兜底。
    params = urllib.parse.urlencode({"q": query})
    html_text = http_text(f"https://duckduckgo.com/html/?{params}", timeout=DEFAULT_TIMEOUT)
    pattern = re.compile(
        r'<a rel="nofollow" class="result__a" href="(?P<href>.*?)".*?>(?P<title>.*?)</a>.*?<a class="result__snippet".*?>(?P<snippet>.*?)</a>',
        re.S,
    )
    results: List[SearchResult] = []
    for match in pattern.finditer(html_text):
        href = html.unescape(match.group("href"))
        parsed = urllib.parse.urlparse(href)
        qs = urllib.parse.parse_qs(parsed.query)
        url = qs.get("uddg", [href])[0]
        results.append(
            SearchResult(
                title=strip_html(match.group("title")),
                url=url,
                source="open-webSearch-fallback",
                snippet=summarize_text(match.group("snippet"), 400),
                metadata={"backend": "duckduckgo_html"},
            )
        )
        if len(results) >= max_results:
            break
    if not results:
        raise GatewayError("免 key Web 搜索未返回可解析结果，可能被限流或页面结构变化。")
    return results


def fetch_url_content(url: str) -> Dict[str, Any]:
    api_key = os.getenv("FIRECRAWL_API_KEY")
    if api_key:
        try:
            data = http_json(
                "https://api.firecrawl.dev/v1/scrape",
                method="POST",
                payload={"url": url, "formats": ["markdown", "html"]},
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=30,
            )
            doc = data.get("data") or data
            content = doc.get("markdown") or doc.get("html") or ""
            return {"url": url, "source": "Firecrawl", "content": summarize_text(content, 3000), "metadata": doc.get("metadata", {})}
        except GatewayError as exc:
            log(f"Firecrawl 抓取失败，回退标准库抓取：{exc}")
    text = http_text(url, timeout=DEFAULT_TIMEOUT)
    title_match = re.search(r"(?is)<title[^>]*>(.*?)</title>", text)
    title = strip_html(title_match.group(1)) if title_match else url
    return {"url": url, "title": title, "source": "standard-fetch", "content": summarize_text(text, 3000), "metadata": {}}


def call_backend(name: str, query: str, max_results: int = MAX_RESULTS, freshness: str = "") -> List[SearchResult]:
    mapping = {
        "arxiv": search_arxiv,
        "semantic_scholar": search_semantic_scholar,
        "openalex": search_openalex,
        "crossref": search_crossref,
        "peps": search_peps,
        "ietf": search_ietf,
        "mdn": search_mdn,
        "osv": search_osv,
        "pypi": search_pypi,
        "npm": search_npm,
        "github": search_github,
        "huggingface": search_huggingface,
        "exa": search_exa,
        "open_web": search_open_web,
    }
    fn = mapping[name]
    if name == "arxiv":
        return fn(query, max_results=max_results, freshness=freshness)
    return fn(query, max_results=max_results)


ROUTES = {
    "academic": ["arxiv", "semantic_scholar", "openalex", "crossref"],
    "standards": ["peps", "ietf", "mdn"],
    "security": ["osv"],
    "packages": ["pypi", "npm"],
    "code": ["github"],
    "models": ["huggingface"],
    "web_cn": ["open_web", "exa"],
    "web": ["exa", "open_web"],
}

PACKAGE_BACKENDS = {
    "pypi": ["pypi"],
    "python": ["pypi"],
    "pip": ["pypi"],
    "npm": ["npm"],
    "node": ["npm"],
    "javascript": ["npm"],
    "js": ["npm"],
}


def run_route(query: str, source_type: str, max_results: int = MAX_RESULTS, freshness: str = "") -> Dict[str, Any]:
    if source_type == "packages":
        route = package_route(query)
    elif source_type == "standards":
        route = standards_route(query)
    else:
        route = ROUTES.get(source_type, ROUTES["web"])
    all_results: List[SearchResult] = []
    errors: List[str] = []
    for backend in route:
        try:
            results = call_backend(backend, query, max_results=max_results, freshness=freshness)
            all_results.extend(results)
        except Exception as exc:  # noqa: BLE001 - 需要保留后端降级信息
            errors.append(f"{backend}: {exc}")
            log(f"后端失败 {backend}: {exc}")
        if len(all_results) >= max_results and source_type not in {"academic"}:
            break
    return {
        "query": query,
        "source_type": source_type,
        "route": route,
        "results": [r.to_dict() for r in dedupe(all_results)[:max_results]],
        "errors": errors,
    }


def package_route(query: str) -> List[str]:
    q = query.lower()
    selected: List[str] = []
    for token, backends in PACKAGE_BACKENDS.items():
        if token in q:
            selected.extend(backends)
    return selected or ROUTES["packages"]


def standards_route(query: str) -> List[str]:
    q = query.lower()
    if "pep" in q or "python" in q:
        return ["peps", "mdn", "ietf"]
    if "rfc" in q or "ietf" in q or "http/" in q or "tls" in q or "dns" in q:
        return ["ietf", "mdn", "peps"]
    if "mdn" in q or "css" in q or "javascript" in q or "browser" in q or "compat" in q or "html" in q:
        return ["mdn", "ietf", "peps"]
    return ROUTES["standards"]


def tool_search(args: Dict[str, Any]) -> Dict[str, Any]:
    query = require_str(args, "query")
    intent = str(args.get("intent") or "")
    language = str(args.get("language") or "")
    freshness = str(args.get("freshness") or "")
    source_type = infer_source_type(query, intent, language)
    return run_route(query, source_type, max_results=int(args.get("max_results") or MAX_RESULTS), freshness=freshness)


def tool_search_sources(args: Dict[str, Any]) -> Dict[str, Any]:
    query = require_str(args, "query")
    source_type = str(args.get("source_type") or infer_source_type(query))
    freshness = str(args.get("freshness") or "")
    return run_route(query, source_type, max_results=int(args.get("max_results") or MAX_RESULTS), freshness=freshness)


def tool_fetch_url(args: Dict[str, Any]) -> Dict[str, Any]:
    url = require_str(args, "url")
    return fetch_url_content(url)


def tool_search_and_fetch(args: Dict[str, Any]) -> Dict[str, Any]:
    query = require_str(args, "query")
    intent = str(args.get("intent") or "")
    max_pages = max(1, min(int(args.get("max_pages") or 2), 5))
    search_result = tool_search({"query": query, "intent": intent, "max_results": max_pages})
    fetched = []
    for item in search_result.get("results", [])[:max_pages]:
        try:
            fetched.append(fetch_url_content(item["url"]))
        except Exception as exc:  # noqa: BLE001
            fetched.append({"url": item.get("url"), "source": "fetch", "error": str(exc)})
    return {"query": query, "search": search_result, "fetched": fetched}


def tool_compare_sources(args: Dict[str, Any]) -> Dict[str, Any]:
    query = require_str(args, "query")
    first_type = infer_source_type(query)
    candidate_types = [first_type]
    if first_type != "web":
        candidate_types.append("web")
    if first_type != "academic":
        candidate_types.append("academic")
    results: List[SearchResult] = []
    errors: List[str] = []
    routes = []
    for source_type in candidate_types[:3]:
        routed = run_route(query, source_type, max_results=3)
        routes.append({"source_type": source_type, "route": routed["route"]})
        errors.extend(routed["errors"])
        for item in routed["results"]:
            results.append(
                SearchResult(
                    title=item["title"],
                    url=item["url"],
                    source=item["source"],
                    snippet=item.get("summary") or "",
                    metadata=item.get("metadata") or {},
                )
            )
    return {"query": query, "routes": routes, "results": [r.to_dict() for r in dedupe(results)[:8]], "errors": errors}


def require_str(args: Dict[str, Any], name: str) -> str:
    value = args.get(name)
    if not isinstance(value, str) or not value.strip():
        raise GatewayError(f"缺少必填参数：{name}")
    return value.strip()


TOOLS = {
    "search": {
        "description": "自动路由到 Web 搜索或权威源 API，返回高质量搜索结果。",
        "handler": tool_search,
        "schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "intent": {"type": "string"},
                "language": {"type": "string"},
                "freshness": {"type": "string"},
                "max_results": {"type": "integer", "minimum": 1, "maximum": 10},
            },
            "required": ["query"],
        },
    },
    "search_sources": {
        "description": "专查论文、标准、包生态、安全、代码、模型等权威源 API。",
        "handler": tool_search_sources,
        "schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "source_type": {
                    "type": "string",
                    "enum": ["academic", "standards", "security", "packages", "code", "models", "web", "web_cn"],
                },
                "freshness": {"type": "string"},
                "max_results": {"type": "integer", "minimum": 1, "maximum": 10},
            },
            "required": ["query"],
        },
    },
    "search_and_fetch": {
        "description": "先搜索再抓取候选页面正文，不保存长期索引。",
        "handler": tool_search_and_fetch,
        "schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "intent": {"type": "string"},
                "max_pages": {"type": "integer", "minimum": 1, "maximum": 5},
            },
            "required": ["query"],
        },
    },
    "fetch_url": {
        "description": "抓取单个 URL 正文，优先 Firecrawl，缺少 key 时使用标准库抓取。",
        "handler": tool_fetch_url,
        "schema": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
        },
    },
    "compare_sources": {
        "description": "用至少两个来源交叉搜索并合并去重。",
        "handler": tool_compare_sources,
        "schema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        },
    },
}


def mcp_tool_list() -> Dict[str, Any]:
    return {
        "tools": [
            {
                "name": name,
                "description": spec["description"],
                "inputSchema": spec["schema"],
            }
            for name, spec in TOOLS.items()
        ]
    }


def content_response(payload: Any) -> Dict[str, Any]:
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(payload, ensure_ascii=False, indent=2),
            }
        ],
        "isError": False,
    }


def handle_mcp(request: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    method = request.get("method")
    req_id = request.get("id")
    try:
        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "quality-search-gateway", "version": "0.1.0"},
            }
        elif method == "notifications/initialized":
            return None
        elif method == "tools/list":
            result = mcp_tool_list()
        elif method == "tools/call":
            params = request.get("params") or {}
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if name not in TOOLS:
                raise GatewayError(f"未知工具：{name}")
            result = content_response(TOOLS[name]["handler"](arguments))
        else:
            raise GatewayError(f"不支持的 MCP 方法：{method}")
        return {"jsonrpc": "2.0", "id": req_id, "result": result}
    except Exception as exc:  # noqa: BLE001
        return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32000, "message": str(exc)}}


def run_stdio() -> None:
    log("MCP stdio 服务已启动")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            response = handle_mcp(request)
            if response is not None:
                print(json.dumps(response, ensure_ascii=False), flush=True)
        except Exception as exc:  # noqa: BLE001
            print(
                json.dumps(
                    {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": f"请求解析失败：{exc}"}},
                    ensure_ascii=False,
                ),
                flush=True,
            )


def run_self_test() -> int:
    tests = [
        ("academic", "RAG evaluation benchmark recent papers"),
        ("standards", "pattern matching Python PEP"),
        ("standards", "HTTP/3 RFC"),
        ("standards", "CSS container queries browser compatibility"),
        ("security", "lodash prototype pollution OSV"),
        ("packages", "pydantic latest PyPI metadata"),
        ("packages", "next npm package metadata"),
        ("models", "text embedding models"),
    ]
    ok = 0
    for source_type, query in tests:
        start = time.time()
        result = run_route(query, source_type, max_results=3)
        elapsed = time.time() - start
        count = len(result.get("results", []))
        status = "通过" if count else "失败"
        print(f"{status}: {source_type} | {query} | 结果 {count} | {elapsed:.1f}s")
        if result.get("errors"):
            print("  降级信息：" + " ; ".join(result["errors"][:2]))
        ok += 1 if count else 0
    return 0 if ok >= 6 else 1


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="高质量搜索路由 MCP 服务器")
    parser.add_argument("--stdio", action="store_true", help="以 MCP stdio 模式运行")
    parser.add_argument("--self-test", action="store_true", help="运行权威源 API 冒烟测试")
    parser.add_argument("--query", help="命令行查询")
    parser.add_argument("--intent", default="", help="查询意图")
    parser.add_argument("--source-type", default="", help="显式来源类型")
    parser.add_argument("--freshness", default="", help="新鲜度偏好，例如 latest/recent/最新")
    args = parser.parse_args(argv)

    if args.stdio:
        run_stdio()
        return 0
    if args.self_test:
        return run_self_test()
    if args.query:
        source_type = args.source_type or infer_source_type(args.query, args.intent)
        print(json.dumps(run_route(args.query, source_type, max_results=5, freshness=args.freshness), ensure_ascii=False, indent=2))
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
