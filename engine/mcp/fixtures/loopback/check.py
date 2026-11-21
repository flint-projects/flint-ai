#!/usr/bin/env python3
"""Independent HTTP and newline JSON-RPC checks for the two pinned revisions."""

import argparse
import http.client
import json
from pathlib import Path
import socket
import subprocess
import time

FIXTURES = Path(__file__).resolve().parents[2] / 'tests' / 'fixtures' / 'mcp'
MODERN = '2026-07-28'
LEGACY = '2025-11-25'
MODERN_WIRE = json.loads((FIXTURES / MODERN / 'requests.json').read_text())
LEGACY_WIRE = json.loads((FIXTURES / LEGACY / 'requests.json').read_text())
CAP = 4 * 1024 * 1024


def request(method, params=None, new_id=3, revision=MODERN):
    body = {'jsonrpc': '2.0', 'id': new_id, 'method': method}
    values = dict(params or {})
    if revision == MODERN:
        values['_meta'] = {
            'io.modelcontextprotocol/protocolVersion': revision,
            'io.modelcontextprotocol/clientCapabilities': {},
        }
    if values:
        body['params'] = values
    return body


def request_headers(body, revision=MODERN, **more):
    fields = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
    if revision:
        fields['MCP-Protocol-Version'] = revision
    if revision == MODERN:
        fields['Mcp-Method'] = body['method']
        param = {'tools/call': 'name', 'resources/read': 'uri'}.get(body['method'])
        if param and param in body['params']:
            fields['Mcp-Name'] = body['params'][param]
    return {**fields, **more}


def decodable(body):
    return b'' if body is None else json.dumps(body, separators=(',', ':'), ensure_ascii=False).encode()


def post(port, body, revision=MODERN, headers=None, raw=None):
    return transfer(port, 'POST', request_headers(body, revision) if headers is None else headers,
                    decodable(body) if raw is None else raw)


def transfer(port, method, headers=None, payload=b''):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        connection.request(method, '/mcp', payload, headers or {})
        result = connection.getresponse()
        status, fields, body = result.status, dict(result.getheaders()), result.read()
        if not body:
            return status, fields, None
        if fields.get('content-type') == 'text/event-stream':
            assert fields.get('x-accel-buffering') == 'no'
            lines = [line[6:] for line in body.splitlines() if line.startswith(b'data: ')]
            body = b'\n'.join(lines)
        return status, fields, json.loads(body)
    finally:
        connection.close()


def local_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def wait_server(instance, port):
    for _ in range(200):
        try:
            socket.create_connection(('127.0.0.1', port), timeout=0.1).close()
            return
        except OSError:
            if instance.poll() is not None:
                raise RuntimeError(f'HTTP server exited: {instance.returncode}')
            time.sleep(0.01)
    raise RuntimeError('HTTP listener did not open')


def modern_http(port):
    tools = MODERN_WIRE['tools']
    status, headers, body = post(port, tools)
    assert status == 200 and 'mcp-session-id' not in headers, (status, headers, body)
    assert body['id'] == 1 and body['result']['resultType'] == 'complete'
    assert [tool['name'] for tool in body['result']['tools']] == ['echo', 'fail', 'slow', 'stats']
    assert body['result']['tools'][0]['inputSchema']['required'] == ['input']
    assert all(transfer(port, method)[0] == 405 for method in ('GET', 'DELETE'))
    assert transfer(port, 'GET', {'Origin': 'https://approved.example'})[0] == 405
    assert transfer(port, 'GET', {'Origin': 'https://evil.example'})[0] == 403
    assert post(port, tools, headers=request_headers(tools, Origin='https://evil.example'))[0] == 403

    discover = MODERN_WIRE['discover']
    status, _, body = post(port, discover)
    assert status == 200 and body['id'] == 'discovery'
    assert MODERN in body['result']['supportedVersions'] and LEGACY in body['result']['supportedVersions']
    assert body['result']['_meta']['io.modelcontextprotocol/serverInfo']['name'] == 'flint-fixture'

    headers = request_headers(tools)
    wrong = dict(headers, **{'MCP-Protocol-Version': '1899-01-01'})
    status, _, body = post(port, tools, headers=wrong)
    assert status == 400 and body['error']['code'] == -32020, body
    wrong = dict(headers, **{'Mcp-Method': 'tools/call'})
    status, _, body = post(port, tools, headers=wrong)
    assert status == 400 and body['error']['code'] == -32020, body
    unsupported = request('tools/list')
    unsupported['params']['_meta']['io.modelcontextprotocol/protocolVersion'] = '1899-01-01'
    status, _, body = post(port, unsupported, headers=dict(headers, **{'MCP-Protocol-Version': '1899-01-01'}))
    assert status == 400 and body['error']['code'] == -32022
    assert body['error']['data'] == {'requested': '1899-01-01', 'supported': [MODERN, LEGACY]}

    status, _, body = post(port, request('tools/unknown'))
    assert status == 404 and body['error']['code'] == -32601, (status, body)
    status, _, body = post(port, request('tools/call', {'name': 'echo', 'arguments': {'input': ''}}))
    assert status == 400 and body['error']['code'] == -32602, (status, body)
    status, events, body = post(port, request('tools/call', {'name': 'fail', 'arguments': {'input': 'x'}}))
    assert status == 200 and body['result']['isError'] and events['content-type'] == 'text/event-stream'
    status, _, body = post(port, request('resources/read', {'uri': 'local://example'}))
    assert status == 200 and body['result']['contents'][0]['text'] == 'explicit fixture contents'

    payload = decodable(tools)
    status, _, _ = post(port, tools, raw=payload.ljust(CAP))
    assert status == 200, status
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        connection.putrequest('POST', '/mcp')
        connection.putheader('Content-Length', str(CAP + 1))
        connection.endheaders()
        assert connection.getresponse().status == 413
    finally:
        connection.close()


def legacy_http(port):
    first = LEGACY_WIRE['open']
    status, headers, body = post(port, first, None)
    assert status == 200 and body['result']['protocolVersion'] == LEGACY, (status, body)
    assert 'resultType' not in body['result'] and '_meta' not in body['result']
    session = headers['mcp-session-id']
    assert len(session) == 32
    fields = request_headers(first, LEGACY, **{'Mcp-Session-Id': session})
    assert transfer(port, 'GET', fields)[0] == 405
    assert post(port, LEGACY_WIRE['list'], headers=fields)[0] == 400
    assert post(port, LEGACY_WIRE['ready'], headers=fields)[0] == 202
    status, _, body = post(port, LEGACY_WIRE['list'], headers=fields)
    assert status == 200 and 'resultType' not in body['result']
    assert transfer(port, 'DELETE', fields)[0] == 204
    assert post(port, LEGACY_WIRE['list'], headers=fields)[0] == 404


def cancellation(id_value):
    return {'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': id_value}}


def stats(port):
    status, _, body = post(port, request('tools/call', {'name': 'stats', 'arguments': {'input': 'x'}}))
    assert status == 200
    return body['result']['structuredContent']


def http_cancellation(port):
    slow = request('tools/call', {'name': 'slow', 'arguments': {'input': 'x'}}, new_id=87)
    with_http = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        with_http.request('POST', '/mcp', decodable(slow), request_headers(slow))
        response = with_http.getresponse()
        assert response.status == 200 and response.getheader('x-accel-buffering') == 'no'
        response.close()
    finally:
        with_http.close()
    assert stats(port) == {'cancelled': 1, 'completed': 0}

    def session():
        status, fields, _ = post(port, LEGACY_WIRE['open'], None)
        assert status == 200
        value = request_headers(slow, LEGACY, **{'Mcp-Session-Id': fields['mcp-session-id']})
        assert post(port, LEGACY_WIRE['ready'], headers=value)[0] == 202
        return value

    first = session()
    other = session()
    body = request('tools/call', {'name': 'slow', 'arguments': {'input': 'x'}},
                   new_id=87, revision=LEGACY)
    with_http = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        with_http.request('POST', '/mcp', decodable(body), first)
        time.sleep(0.1)
    finally:
        with_http.close()
    # Neither dropping legacy TCP nor a different session with the same JSON-RPC ID cancels this tool.
    assert post(port, cancellation(87), headers=other)[0] == 202
    time.sleep(0.1)
    assert post(port, cancellation(999), headers=first)[0] == 202
    assert post(port, cancellation(87), headers=first)[0] == 202
    assert stats(port) == {'cancelled': 2, 'completed': 0}
    assert transfer(port, 'DELETE', first)[0] == 204
    assert transfer(port, 'DELETE', other)[0] == 204


def stdio_cancellation(exe):
    with subprocess.Popen([exe, 'stdio', 'dual'], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as server:
        try:
            messages = [request('tools/call', {'name': 'slow', 'arguments': {'input': 'x'}}, new_id=97),
                        cancellation(98), cancellation(97),
                        request('tools/call', {'name': 'stats', 'arguments': {'input': 'x'}}, new_id=99)]
            server.stdin.write(b''.join(decodable(message) + b'\n' for message in messages[:2]))
            server.stdin.flush()
            time.sleep(0.1)
            server.stdin.write(b''.join(decodable(message) + b'\n' for message in messages[2:]))
            server.stdin.flush()
            body = json.loads(server.stdout.readline())
            assert body['id'] == 99 and body['result']['structuredContent'] == {'cancelled': 1, 'completed': 0}
            server.stdin.close()
            assert server.wait(timeout=8) == 0
        finally:
            if server.poll() is None:
                server.kill()


def stdio_wire(exe):
    with subprocess.Popen([exe, 'stdio', 'dual'], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as server:
        try:
            for message in [MODERN_WIRE['tools'], MODERN_WIRE['discover'], [], {'jsonrpc': '2.0', 'id': None}]:
                server.stdin.write(decodable(message) + b'\n')
                server.stdin.flush()
                wire = server.stdout.readline()
                assert wire.endswith(b'\n')
                assert json.loads(wire)['jsonrpc'] == '2.0'
            server.stdin.close()
            assert server.wait(timeout=8) == 0
        finally:
            if server.poll() is None:
                server.kill()


def with_server(exe, server_mode, callback):
    port = local_port()
    with subprocess.Popen([exe, 'http', server_mode, str(port)]) as server:
        try:
            wait_server(server, port)
            callback(port)
        finally:
            server.terminate()
            server.wait(timeout=8)


def check(exe):
    assert subprocess.run([exe, 'http', 'dual', str(local_port()), '0.0.0.0'], timeout=8).returncode == 42
    stdio_wire(exe)
    stdio_cancellation(exe)
    for mode in ('modern', 'legacy', 'fallback'):
        subprocess.run([exe, 'client', exe, mode], check=True, timeout=12)
        print(f'stdio {mode} discovery and typed round trips')
    def check_http(port):
        modern_http(port)
        legacy_http(port)
        http_cancellation(port)
        for mode in ('modern', 'legacy'):
            subprocess.run([exe, 'client', f'http://127.0.0.1:{port}/mcp', mode], check=True, timeout=12)
    with_server(exe, 'dual', check_http)
    with_server(exe, 'legacy', lambda port: subprocess.run(
        [exe, 'client', f'http://127.0.0.1:{port}/mcp', 'fallback'], check=True, timeout=12))
    print('HTTP modern, legacy, fallback, headers, Origin and 4 MiB envelope passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('executable', type=lambda value: str(Path(value).resolve()))
    check(parser.parse_args().executable)
