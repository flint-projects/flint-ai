# flint:engine-mcp acceptance traceability

Source: `handoff/specs/tier-7/mcp.md` section 7. Loopback evidence comes from the standalone app
`fixtures/loopback/app.d` linked against the native HTTP providers (DMD and LDC) and driven by the
independent peers `fixtures/loopback/check.py`, `mrtr_peer.py` and `header_peer.py`.
Compile-negative fixtures run with `python3 engine/mcp/negative/check.py dmd ldc2`.

| # | Section 7 item | Covering test or fixture | Status |
| --- | --- | --- | --- |
| 1 | modern_discovery: first request can be tools/list with metadata | `tests/protocol.d` first unittest (line 28, first dispatch is `tools/list`); `check.py:modern_http` | covered |
| 2 | modern_discovery: server/discover without initialize | `check.py:modern_http` (`discover` lists both revisions and serverInfo) | covered |
| 3 | modern_http: GET/DELETE 405, no session header minted | `check.py:modern_http` | covered |
| 4 | modern_http: conflicting header/body revision or method fails before tools run | `check.py:modern_http` (-32020 for header/body mismatch, -32022 with supported list for unsupported version); `tests/protocol.d:tool_errors: ...` (missing metadata -> -32602, tool not run) | covered, added |
| 5 | legacy_compat: initialize -> initialized -> tools/list with exactly 2025-11-25 and no modern fields | `check.py:legacy_http` (no `resultType`/`_meta`, session lifecycle, DELETE); stdio `client ... legacy` | covered |
| 6 | era_fallback: modern/legacy/dual client x server matrix incl. unsupported-version retry | `check.py:era_matrix` (HTTP: modern, legacy, dual servers x modern, legacy, fallback clients with expected success/refusal); stdio modern/legacy/fallback clients; -32022 retry data in `modern_http` | added (full matrix), covered |
| 7 | stdio_clean: every stdout line is valid JSON-RPC | `check.py:stdio_wire` (valid, batch `[]`, null id); `tests/stdio_framing.d:a stdio reply that has started is never truncated by per-request cancellation` | covered |
| 8 | stdio_clean: diagnostics cannot leak into the protocol stream | `mrtr_peer.py` stdio modes ("bounded stderr draining", allowlisted environment) | covered |
| 9 | origin_auth: invalid Origin -> 403 | `check.py:modern_http` | covered |
| 10 | origin_auth: nonlocal listener without auth fails startup | `check.py:check` (`http dual <port> 0.0.0.0` exits 42 = permissionDenied at open) | covered |
| 11 | tool_errors: unknown method / invalid params are JSON-RPC errors | `check.py:modern_http` (-32601, -32602); `tests/protocol.d:tool_errors: protocol faults use JSON-RPC errors and never run tool code; tool failures set isError` | covered, added |
| 12 | tool_errors: application failure returns isError, malformed inputs never invoke tool code | `tests/protocol.d:tool_errors: ...` (missing/wrong-type/too-short/too-long/non-object arguments, unknown tool, missing name, missing metadata, truncated JSON, batch: invocation counter stays 0; failure -> 200 with isError and no `error`); `check.py:modern_http` (`fail` tool) | added, covered |
| 13 | registry_pagination: cursor from another generation rejected | `tests/protocol.d` first unittest (second registry rejects the cursor with 400) | covered |
| 14 | registry_pagination: full pagination yields every tool exactly once | `tests/protocol.d:registry_pagination: following every cursor lists each registered tool exactly once` (37 tools, >= 3 pages) | added |
| 15 | cancellation_versions: modern SSE close cancels its request | `check.py:http_cancellation` (stats `cancelled: 1`) | covered |
| 16 | cancellation_versions: legacy explicit cancel; no crossing request IDs or sessions | `check.py:http_cancellation` (other session same ID and wrong ID do not cancel); `check.py:stdio_cancellation` | covered |
| 17 | MRTR input requests, bounded rounds, rejection when unsupported | `mrtr_peer.py` (modes mrtr, reject-mrtr, bounded-mrtr over HTTP and stdio) | covered |
| 18 | Schema-mirrored `x-mcp-header` fields | `header_peer.py` (headers, reject-headers); `tests/protocol.d` second unittest (encoding rules) | covered |
| 19 | 4 MiB message cap | `check.py:modern_http` (exact 4 MiB body accepted, 4 MiB + 1 -> 413); third unittest (malformed envelopes) | covered |
| 20 | mcp_bench: 100k 1 KiB tool calls over stdio and HTTP, no hot D allocations | `bench/run.py` (reports GC counters and cross-transport checksums) | covered (not rerun in this review) |
| 21 | Fuzz seeds: truncated input, maximum lengths, empty values | third unittest (`{`, `{}`, `[]`, bad ids, duplicate keys); item 12 truncated JSON; item 19 | covered |
| 22 | Fuzz seeds: cancellation, generation reuse | items 15-16; item 13 (cursor of another registry generation) | covered |
| 23 | Borrowed request cannot be retained; unsafe provider cannot register | `negative/check.py` (`leak_input.d`, `unsafe_provider.d`) | covered (runner added) |

## Findings (fixed)

- A well-formed JSON batch (`[ {...} ]`) was refused with JSON-RPC code -32700 (parse error). The
  envelope decoder now validates a rejected array document and answers -32600 (invalid request) when it is
  well-formed JSON, keeping -32700 for malformed input. `tool_errors` asserts both codes, including `[]`.

## Stub review

No always-success or ignored-input paths found. `McpTool.readOnly` is emitted as `readOnlyHint`
metadata only, as the spec requires (it never authorizes invocation).

## Verification (this review)

- `rtest acc-cloud mcp both`: DMD rc=0, LDC rc=0 (2 modules passed).
- Loopback app built with DMD and LDC against the pinned curl/llhttp/nghttp2/OpenSSL archives; `check.py`, `mrtr_peer.py`, `header_peer.py`: rc=0 for both builds.
- `negative/check.py dmd ldc2`: 2/2 rejected on each compiler.
- `tools/gates.py --package mcp --gate structural`: rc=0. `tools/quality.py --path engine/mcp`: 0 issues.
