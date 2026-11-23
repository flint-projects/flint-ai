#!/usr/bin/env python3
"""Exercise real pinned HTTP on recipe-versioned provider streams, entirely on loopback."""
from collections import Counter, defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import subprocess
import sys
from threading import Thread
import time


def event(value):
    data = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return f"data: {data}\r\n\r\n".encode()


def responses():
    return [
        {"type": "response.output_text.delta", "delta": "hé"},
        {"type": "response.completed", "response": {"usage": {"input_tokens": 7, "output_tokens": 3}}},
    ]


def anthropic():
    return [
        {"type": "message_start", "message": {"usage": {"input_tokens": 7, "output_tokens": 1}}},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "hé"}},
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 3}},
        {"type": "message_stop"},
    ]


def gemini():
    return [
        {"candidates": [{"content": {"parts": [{"text": "hé"}]}}]},
        {"candidates": [{"finishReason": "STOP"}], "usageMetadata": {"promptTokenCount": 7, "candidatesTokenCount": 3}},
    ]


def chat():
    return [
        {"choices": [{"index": 0, "delta": {"content": "hé"}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        {"choices": [{"index": 0, "delta": {"content": ""}, "finish_reason": "stop"}],
         "usage": {"prompt_tokens": 7, "completion_tokens": 3}},
        "[DONE]",
    ]


def tool_calls(kind):
    """A complete tool call with no terminal event: the client cancels after observing it."""
    arguments = '{"a":1}'
    if kind in ("openAI", "routerResponses"):
        return [
            {"type": "response.output_item.added",
             "item": {"type": "function_call", "id": "a", "call_id": "1", "name": "get"}},
            {"type": "response.function_call_arguments.delta", "item_id": "a", "delta": arguments},
            {"type": "response.function_call_arguments.done", "item_id": "a", "arguments": arguments},
        ]
    if kind == "anthropic":
        return [
            {"type": "message_start", "message": {"usage": {"input_tokens": 7, "output_tokens": 1}}},
            {"type": "content_block_start", "index": 0,
             "content_block": {"type": "tool_use", "id": "a", "name": "get", "input": {}}},
            {"type": "content_block_delta", "index": 0,
             "delta": {"type": "input_json_delta", "partial_json": arguments}},
            {"type": "content_block_stop", "index": 0},
        ]
    if kind == "gemini":
        return [{"candidates": [{"content": {"parts": [{"functionCall": {"name": "get", "args": {"a": 1}}}]}}]}]
    return [
        {"choices": [{"index": 0, "delta": {"tool_calls": [
            {"index": 0, "id": "call_1", "function": {"name": "get", "arguments": arguments}}]},
            "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
    ]


class Peer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    hits = Counter()
    identities = defaultdict(set)
    errors = []

    def log_message(self, message, *args):
        pass

    def examine(self, request):
        if self.path.startswith("/v1beta/models/"):
            match = re.fullmatch(r"/v1beta/models/([a-z]+):streamGenerateContent\?alt=sse", self.path)
            assert match
            assert self.headers["X-Goog-Api-Key"] == "test-key"
            assert self.headers.get("Authorization") is None
            assert request["generationConfig"] == {"candidateCount": 1, "maxOutputTokens": 40, "temperature": 0.25}
            content = request["contents"][0]["parts"][0]["text"]
            return "gemini", match[1], gemini(), content
        kind, output, content_key, token_key = {
            "/v1/responses": ("openAI", responses(), "input", "max_output_tokens"),
            "/v1/messages": ("anthropic", anthropic(), "messages", "max_tokens"),
            "/api/v1/responses": ("routerResponses", responses() + ["[DONE]"], "input", "max_output_tokens"),
            "/api/v1/chat/completions": ("routerChat", chat(), "messages", "max_tokens"),
        }[self.path]
        if kind == "anthropic":
            assert self.headers["Anthropic-Version"] == "2023-06-01"
            assert self.headers["X-Api-Key"] == "test-key"
        else:
            assert self.headers["Authorization"] == "Bearer test-key"
        if kind.startswith("router"):
            assert request["provider"] == {"require_parameters": True}
        assert request["stream"] is True and request[token_key] == 40 and request["temperature"] == 0.25
        assert request[content_key][0]["role"] == "user"
        return kind, request["model"], output, request[content_key][0]["content"]

    def do_POST(self):
        try:
            assert self.headers["Content-Type"] == "application/json"
            assert self.headers["Accept"] == "text/event-stream"
            identity = self.headers["X-Flint-Request-Id"]
            assert re.fullmatch(r"[0-9a-f]{32}", identity)
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            kind, model, output, content = self.examine(request)
            assert content == 'prompt\n"quoted" 🦊'
            key = kind, model
            assert identity not in self.identities[key]
            self.identities[key].add(identity)
            self.hits[key] += 1
        except Exception as error:
            self.errors.append(repr(error))
            self.send_error(400)
            return

        failure = model == "rejected" or (model == "fixture" and self.hits[key] == 1)
        if failure:
            payload = event({"type": "response.output_text.delta", "delta": "invalid"})
        else:
            if model in ("early", "cancel"):
                output = output[:3 if kind == "anthropic" else 1]
            elif model == "toolcancel":
                output = tool_calls(kind)
            payload = b": provider heartbeat\r\n" + b"".join(map(event, output))
        self.send_response(429 if failure else 200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            for segment in (payload[:7], payload[7:17], payload[17:]):
                self.wfile.write(segment)
                self.wfile.flush()
                time.sleep(0.001)
        except (BrokenPipeError, ConnectionResetError):
            if model not in ("cancel", "toolcancel"):
                self.errors.append("unexpected connection retirement")


def main():
    if len(sys.argv) < 2:
        raise SystemExit("provide the linked flint:engine-ai unittest command")
    with ThreadingHTTPServer(("127.0.0.1", 0), Peer) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run(sys.argv[1:], check=False, timeout=180, env={
                **os.environ, "FLINT_AI_TEST_URL": f"http://127.0.0.1:{server.server_port}",
            })
        finally:
            server.shutdown()
            thread.join()
    if result.returncode != 0 or Peer.errors:
        raise SystemExit(f"linked fixtures failed with exit {result.returncode}, peer errors {Peer.errors}")
    for provider in ("openAI", "anthropic", "gemini", "routerResponses", "routerChat"):
        assert {key[1]: hits for key, hits in Peer.hits.items() if key[0] == provider} == {
            "fixture": 2, "rejected": 1, "early": 1, "cancel": 1, "toolcancel": 1,
        }
    print("Verified 30 scoped POSTs, five identities regenerated on retry and zero cancelled-request replays")


if __name__ == "__main__":
    main()
