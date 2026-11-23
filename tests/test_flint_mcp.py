"""flint mcp: the ADR-021 section 6 tools over MCP stdio, built on flint:engine-mcp (Milestone 9, ADR-027)."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import os
import sys
sys.path.insert(0, str(Path(os.environ.get('FLINT_ROOT') or Path(__file__).resolve().parents[2]) / 'tests'))
from flint_testing import FLINT_ROOT, package_dir, repo_dir  # noqa: E402,F401
from test_flint_cli import FLINT, ROOT, codes, environment, flint_json, setUpModule  # noqa: F401

NATIVE_LINKED = 'BEGIN FLINT NATIVE' in (package_dir('engine-web') / 'dub.sdl').read_text()
TOOLS = ['search_api', 'get_symbol', 'get_example', 'explain_error', 'describe_project', 'resolved_config',
         'dependency_graph', 'generate', 'build', 'test', 'check']


class Client:
    def __init__(self, cwd, log):
        self.process = subprocess.Popen([str(FLINT), 'mcp', '--log', str(log)], cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment())
        self.next = 0

    def request(self, method, params=None):
        self.next += 1
        message = {'jsonrpc': '2.0', 'id': self.next, 'method': method}
        if params is not None:
            message['params'] = params
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())

    def notify(self, method):
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': method}) + '\n')
        self.process.stdin.flush()

    def call(self, name, arguments):
        return self.request('tools/call', {'name': name, 'arguments': arguments})

    def close(self):
        self.process.stdin.close()
        return self.process.wait(timeout=60)


@unittest.skipUnless(NATIVE_LINKED, 'flint:engine-mcp links the native HTTP providers, which are not installed')
class McpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='flint-mcp-')
        status, document = flint_json('new', 'shop', cwd=cls.temporary.name)
        assert status == 0, document
        cls.project = Path(cls.temporary.name) / 'shop'
        cls.log = Path(cls.temporary.name) / 'calls.jsonl'
        cls.client = Client(cls.project, cls.log)
        cls.initialized = cls.client.request('initialize', {
            'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}})
        cls.client.notify('notifications/initialized')

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.temporary.cleanup()

    def structured(self, reply):
        self.assertNotIn('error', reply, reply)
        return reply['result']

    def test_1_the_server_lists_the_section_6_tools(self):
        self.assertEqual(self.initialized['result']['serverInfo']['name'], 'flint')
        tools = self.client.request('tools/list')['result']['tools']
        self.assertEqual([t['name'] for t in tools], TOOLS)
        schema = next(t for t in tools if t['name'] == 'search_api')['inputSchema']
        self.assertIn('query', schema['properties'])

    def test_2_knowledge_tools_answer_from_the_pinned_index(self):
        result = self.structured(self.client.call('get_symbol', {'name': 'flint.os.run'}))
        self.assertFalse(result['isError'])
        self.assertEqual(result['structuredContent']['symbols'][0]['qualified'], 'flint.os.run')
        result = self.structured(self.client.call('explain_error', {'code': 'FLINT-E0401'}))
        self.assertEqual(result['structuredContent']['codes'][0]['code'], 'FLINT-E0401')
        result = self.structured(self.client.call('resolved_config', {'profile': 'prod'}))
        keys = {k['key']: k for k in result['structuredContent']['keys']}
        self.assertEqual(keys['app.greeting']['value'], '"Good day"')

    def test_3_the_build_loop_reports_failures_as_tool_errors(self):
        result = self.structured(self.client.call('build', {}))
        self.assertFalse(result['isError'], result['content'][0]['text'][:500])
        broken = self.project / 'src/shop/broken.d'
        broken.write_text('module shop.broken;\n\n@safe:\n\nint f() { return undefinedSymbol; }\n')
        try:
            result = self.structured(self.client.call('build', {}))
            self.assertTrue(result['isError'])
            self.assertEqual(codes(result['structuredContent']), ['FLINT-E0701'])
        finally:
            broken.unlink()
        result = self.structured(self.client.call('generate', {'kind': 'entity', 'name': 'Order', 'plan': True}))
        self.assertEqual(result['structuredContent']['files'][0]['path'], 'src/shop/order/order.d')

    def test_4_invalid_arguments_and_the_call_log(self):
        reply = self.client.call('search_api', {'query': ''})
        self.assertEqual(reply['error']['code'], -32602)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertTrue(calls)
        self.assertTrue(all({'tool', 'arguments', 'exit_code', 'millis'} <= set(c) for c in calls))
        self.assertIn('build', [c['tool'] for c in calls])


if __name__ == '__main__':
    unittest.main()
