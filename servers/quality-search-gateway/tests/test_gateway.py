import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("server", ROOT / "server.py")
server = importlib.util.module_from_spec(SPEC)
sys.modules["server"] = server
SPEC.loader.exec_module(server)


class GatewayTests(unittest.TestCase):
    def test_infer_source_type(self):
        self.assertEqual(server.infer_source_type("RAG evaluation benchmark recent papers"), "academic")
        self.assertEqual(server.infer_source_type("HTTP/3 RFC"), "standards")
        self.assertEqual(server.infer_source_type("lodash prototype pollution OSV"), "security")
        self.assertEqual(server.infer_source_type("pydantic latest PyPI metadata"), "packages")
        self.assertEqual(server.infer_source_type("Hugging Face text embedding models"), "models")
        self.assertEqual(server.infer_source_type("RAND policy report AI"), "think_tanks")

    def test_dedupe_by_doi_and_url(self):
        items = [
            server.SearchResult("a", "https://example.com/?utm_source=x", "x", metadata={"doi": "10.1/a"}),
            server.SearchResult("b", "https://example.com/", "y", metadata={"doi": "10.1/a"}),
            server.SearchResult("c", "https://example.org/?utm_source=x", "z"),
            server.SearchResult("d", "https://example.org/", "z"),
        ]
        out = server.dedupe(items)
        self.assertEqual(len(out), 2)

    def test_tool_list_contains_expected_tools(self):
        tools = {tool["name"] for tool in server.mcp_tool_list()["tools"]}
        self.assertLessEqual(
            {"search", "search_sources", "latest_papers", "search_and_fetch", "fetch_url", "compare_sources", "diagnostics"},
            tools,
        )

    def test_meaningful_tokens(self):
        self.assertEqual(server.meaningful_tokens("pattern matching Python PEP"), ["pattern", "matching"])

    def test_arxiv_latest_helpers(self):
        self.assertTrue(server.wants_latest("latest artificial intelligence papers"))
        self.assertFalse(server.query_requests_latest("RAG evaluation benchmark recent papers"))
        self.assertTrue(server.query_requests_latest("latest artificial intelligence papers"))
        self.assertEqual(server.arxiv_search_query("latest artificial intelligence papers"), "cat:cs.AI")
        self.assertEqual(server.arxiv_search_query("latest papers", category="cs.LG"), "cat:cs.LG")
        self.assertEqual(server.normalize_arxiv_category("machine learning"), "cs.LG")
        self.assertEqual(server.arxiv_search_query("RAG evaluation benchmark"), "all:RAG evaluation benchmark")

    def test_openalex_empty_abstract_is_safe(self):
        result = server.SearchResult(
            "x",
            "https://example.com",
            "OpenAlex",
            snippet=server.summarize_text(None, 20),
        )
        self.assertEqual(result.snippet, "")

    def test_framed_response_encoding(self):
        payload = server.encode_mcp_frame({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})
        self.assertTrue(payload.startswith(b"Content-Length: "))
        self.assertIn(b"\r\n\r\n", payload)

    def test_backend_registry_defaults(self):
        self.assertIn("semantic_scholar", server.BACKENDS)
        self.assertFalse(server.BACKENDS["semantic_scholar"].enabled_by_default)
        self.assertNotIn("semantic_scholar", server.ROUTES["academic"])
        self.assertEqual(server.ROUTES["think_tanks"], ["exa", "open_web"])


if __name__ == "__main__":
    unittest.main()
