# Model Context Protocol

`McpServer` serves registered tools and resources over newline-delimited stdio or Streamable HTTP. `McpClient` uses either an explicit HTTP destination or an absolute subprocess executable with explicit argument and environment lists. Standard output carries protocol frames, and the client drains child diagnostics through a separate bounded stream.

The default wire revision is `2026-07-28`. Configure `acceptLegacy` to control fallback to the separate `2025-11-25` capability handshake and session state. The modern transport scopes operation cancellation to an HTTP request. Legacy cancellation matches the session and JSON-RPC identity. HTTP binds loopback by default. External listeners require an authorization delegate. An Origin header must match a configured allowed origin, and TLS can be configured on the listener.

Registered tool inputs are validated against generated schemas. Custom `x-mcp-header` annotations encode supported fields from those schemas. The MRTR client uses the configured elicitation handler and bounds the number of additional rounds. Applications own authorization and policy for registered tools and resources. The default limits are a 4 MiB message and 64 in-flight operations.

## Linux verification

Prepare the pinned HTTP and Web dependencies before running the linked tests:

```sh
dub test :mcp --compiler=dmd
dub test :mcp --compiler=ldc2
python3 tools/gates.py --package mcp --gate structural
python3 tools/quality.py --path packages/mcp
```

The standalone app in `fixtures/loopback` exercises both registered revisions. With the app linked to the native HTTP providers, run its executable through `check.py`, `mrtr_peer.py` and `header_peer.py`. The independent peers check framing and limits, stdout and stderr handling, cancellation, version fallback, tool validation, header encoding and elicitation. The DMD, LDC and Linux LDC ASan receipts are indexed in `artifacts/tasks/m5-mcp/final-correctness.json`.

`bench/run.py` drives a fixed 100,000-call stdio round and a 100,000-call HTTP round with a 1 KiB tool value. It checks the result checksums across transports. Each producer reports actual completed calls, elapsed time and D GC counters for the measured client thread. Local release-probe timings depend on the host and transport backend.
