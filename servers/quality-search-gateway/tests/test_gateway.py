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
        self.assertLessEqual({"search", "search_sources", "search_and_fetch", "fetch_url", "compare_sources"}, tools)

    def test_meaningful_tokens(self):
        self.assertEqual(server.meaningful_tokens("pattern matching Python PEP"), ["pattern", "matching"])


if __name__ == "__main__":
    unittest.main()
