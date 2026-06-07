# Codex MCP Registry

Portable MCP registry for Codex.

This repository stores sanitized MCP configuration templates and setup scripts.
It must not contain API keys, cookies, OAuth tokens, certificates, or full
private Codex config files.

## Layout

- `registry/`: one TOML snippet per MCP server.
- `profiles/current.toml`: the current machine's MCP set, with local paths
  templated where practical.
- `servers/`: checked-in local MCP servers and tools.
- `docs/`: supporting notes and curated source lists.
- `scripts/install-mcps.ps1`: installs selected MCP snippets into
  `%USERPROFILE%\.codex\config.toml`.
- `scripts/validate-mcps.ps1`: checks snippet syntax, missing placeholders, and
  obvious secret patterns.

## Current MCPs

- `tia_portal_v17`: local Siemens TIA Portal Openness V17 MCP.
- `openaiDeveloperDocs`: OpenAI official developer docs MCP.
- `deepwiki`: DeepWiki repository documentation MCP.
- `context7`: current library/framework documentation MCP.
- `github`: GitHub Copilot MCP, token via `GITHUB_PAT_TOKEN`.
- `office_document`: file-level Office document MCP.
- `quality_search_gateway`: high-quality search gateway for Web search and
  authoritative source APIs such as arXiv, Semantic Scholar, OpenAlex,
  Crossref, PEPs, IETF, MDN BCD, OSV, PyPI, npm, GitHub, and Hugging Face.

See `docs/engineering-knowledge-sources.md` for the curated engineering source
list used to guide search routing.

## Safety

Use environment variables for secrets. For example, the GitHub MCP uses:

```toml
bearer_token_env_var = "GITHUB_PAT_TOKEN"
```

Do not commit `auth.json`, `.env`, raw bearer tokens, cookies, or full
`config.toml` files.

