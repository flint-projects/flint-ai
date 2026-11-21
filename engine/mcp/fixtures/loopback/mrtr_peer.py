#!/usr/bin/env python3
"""Independent MRTR peer with opaque state and strict fresh-ID checks."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import subprocess
import sys
import threading
from pathlib import Path

REVISION = '2026-07-28'
OPAQUE = 'opaque\nstate=字\\valid'
CALL = {'input': 'hello'}


class Peer:
    def __init__(self, mode):
        self.mode = mode
        self.ids = set()
        self.rounds = 0

    def exchange(self, request, fields):
        identity, method, params = request['id'], request['method'], request['params']
        assert identity not in self.ids
        self.ids.add(identity)
        meta = params['_meta']
        assert meta['io.modelcontextprotocol/protocolVersion'] == REVISION
        caps = meta['io.modelcontextprotocol/clientCapabilities']
        assert caps == ({'elicitation': {'form': {}}} if self.mode == 'mrtr' else {})
        if fields is not None:
            assert fields['Mcp-Method'] == method and fields['MCP-Protocol-Version'] == REVISION
        if method == 'server/discover':
            result = {'supportedVersions': [REVISION], 'capabilities': {'tools': {}}}
        elif method == 'tools/list':
            result = {'tools': [{'name': 'echo', 'inputSchema': {'type': 'object'}}]}
        else:
            assert method == 'tools/call'
            if fields is not None:
                assert fields['Mcp-Name'] == 'echo'
            assert params['name'] == 'echo' and params['arguments'] == CALL
            if self.rounds:
                assert params['requestState'] == OPAQUE
                if self.mode == 'mrtr':
                    assert params['inputResponses'] == {'form-1': {'action': 'accept', 'content': {'answer': 'explicit'}}}
                else:
                    assert 'inputResponses' not in params
            else:
                assert 'requestState' not in params and 'inputResponses' not in params
            self.rounds += 1
            if self.rounds == 1 or self.mode == 'bounded-mrtr':
                result = {'resultType': 'input_required', 'requestState': OPAQUE}
                if self.mode != 'bounded-mrtr':
                    result['inputRequests'] = {
                        'form-1': {
                            'method': 'elicitation/create',
                            'params': {'mode': 'form', 'message': 'Fixture', 'requestedSchema': {'type': 'object'}},
                        },
                    }
            else:
                result = {'content': [{'type': 'text', 'text': 'hello'}], 'isError': False}
        return {'jsonrpc': '2.0', 'id': identity, 'result': {'resultType': 'complete', **result}}


def check(executable, mode):
    peer = Peer(mode)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def do_POST(self):
            try:
                incoming = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                result = json.dumps(peer.exchange(incoming, self.headers)).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                body = b': fixture\n\ndata: ' + result + b'\n\n'
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                self.send_error(500)
                raise

    with HTTPServer(('127.0.0.1', 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            endpoint = f'http://127.0.0.1:{server.server_port}/mcp'
            subprocess.run([executable, 'client', endpoint, mode], check=True, timeout=12)
        finally:
            server.shutdown()
            worker.join()
    assert peer.rounds == (1 if mode == 'reject-mrtr' else 2), peer.rounds
    print(f'{mode}: {peer.rounds} correlated endpoint requests')


def check_stdio(executable, mode):
    child_script = str(Path(__file__).resolve())
    subprocess.run([executable, 'client', sys.executable, mode, child_script], check=True, timeout=12)
    print(f'{mode} stdio: scoped process arguments, allowlisted environment, bounded stderr draining')


def serve_stdio(mode):
    assert os.environ['FLINT_MCP_FIXTURE'] == 'true'
    assert not os.environ.get('FLINT_TEST_PARENT_ENV')
    assert not os.environ.get('SSH_AUTH_SOCK')
    sys.stderr.write('x' * 131_072)
    sys.stderr.flush()
    peer = Peer(mode)
    for wire in sys.stdin:
        outcome = peer.exchange(json.loads(wire), None)
        print(json.dumps(outcome), flush=True)
    assert peer.rounds == (1 if mode == 'reject-mrtr' else 2)


if __name__ == '__main__':
    if sys.argv[1] == '--stdio':
        serve_stdio(sys.argv[2])
    else:
        os.environ['FLINT_TEST_PARENT_ENV'] = 'must-not-be-inherited'
        for selected in ('mrtr', 'reject-mrtr', 'bounded-mrtr'):
            check(sys.argv[1], selected)
            check_stdio(sys.argv[1], selected)
