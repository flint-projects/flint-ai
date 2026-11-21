#!/usr/bin/env python3
"""An independent modern peer enforcing schema-mirrored HTTP fields."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import base64
import json
import subprocess
import sys
import threading

REVISION = '2026-07-28'


def exercise(exe, mode):
    listings = 0
    calls = 0
    identities = set()
    observed_errors = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def do_POST(self):
            nonlocal listings, calls
            try:
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                method, identity = request['method'], request['id']
                assert identity not in identities
                identities.add(identity)
                assert self.headers['Mcp-Method'] == method
                assert self.headers['MCP-Protocol-Version'] == REVISION
                reply = {'jsonrpc': '2.0', 'id': identity}
                status = 200
                if method == 'server/discover':
                    result = {'supportedVersions': [REVISION], 'capabilities': {'tools': {}}}
                elif method == 'tools/list':
                    listings += 1
                    schema = {
                        'type': 'object',
                        'properties': {
                            'nested': {'properties': {
                                'region': {'type': 'string', 'x-mcp-header': 'Old' if listings < 3 else 'Region'},
                            }},
                            'enabled': {'type': 'boolean', 'x-mcp-header': 'Enabled'},
                            'limit': {'type': 'integer', 'x-mcp-header': 'Limit'},
                        },
                    }
                    if mode == 'reject-headers':
                        schema['properties']['nested']['items'] = {'type': 'string', 'x-mcp-header': 'Forbidden'}
                    result = {'tools': [{'name': 'echo', 'inputSchema': schema}]}
                else:
                    assert method == 'tools/call' and mode != 'reject-headers'
                    calls += 1
                    assert self.headers['Mcp-Name'] == 'echo'
                    assert self.headers['Mcp-Param-Enabled'] == 'false'
                    assert self.headers['Mcp-Param-Limit'] == '42'
                    arg = request['params']['arguments']['nested']['region']
                    token = '=?base64?' + base64.b64encode(arg.encode()).decode() + '?='
                    if calls == 1:
                        assert self.headers['Mcp-Param-Old'] == token
                        reply['error'] = {'code': -32020, 'message': 'Schema updated'}
                        result = None
                        status = 400
                    else:
                        assert self.headers['Mcp-Param-Region'] == token
                        assert 'Mcp-Param-Old' not in self.headers
                        result = {'content': [{'type': 'text', 'text': 'hello'}], 'isError': False}
                if result is not None:
                    reply['result'] = {'resultType': 'complete', **result}
                encoded = json.dumps(reply).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            except Exception as error:
                observed_errors.append(error)
                self.send_error(500)

    with HTTPServer(('127.0.0.1', 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            endpoint = f'http://127.0.0.1:{server.server_port}/mcp'
            subprocess.run([exe, 'client', endpoint, mode], check=True, timeout=12)
        finally:
            server.shutdown()
            worker.join()
    assert not observed_errors, observed_errors
    assert calls == (0 if mode == 'reject-headers' else 2)
    print(f'{mode}: listings={listings} tool_calls={calls}')


if __name__ == '__main__':
    for selected in ('headers', 'reject-headers'):
        exercise(sys.argv[1], selected)
