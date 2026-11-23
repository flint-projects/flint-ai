# flint:engine-ai acceptance traceability

Source: `handoff/specs/tier-7/ai.md` section 7. Transport tests run the linked unittest binary under
`tests/local_peer.py` (a loopback HTTP peer that speaks the five dialects with recorded,
sanitized events); without `FLINT_AI_TEST_URL` they return early. No real AI provider is contacted.
Compile-negative fixtures run with `python3 packages/engine-ai/negative/check.py dmd ldc2`.

| # | Section 7 item | Covering test or fixture | Status |
| --- | --- | --- | --- |
| 1 | provider_fixtures: success per adapter (OpenAI, Anthropic, Gemini, OpenRouter Responses, OpenRouter Chat) | peer: `tests/client_behavior.d:real transport verifies provider-specific envelopes, prestream retries and cancellation` (model `fixture`) | covered |
| 2 | provider_fixtures: prestream error per adapter (429, retry with fresh identity, exhausted retry) | same test (models `fixture` first 429 then success, `rejected`); peer asserts fresh `X-Flint-Request-Id` per attempt | covered |
| 3 | provider_fixtures: midstream provider error per adapter | `tests/provider_behavior.d:provider_fixtures midstream: every adapter turns a provider error after text into one failure` | added |
| 4 | provider_fixtures: midstream truncation (EOF before terminal event = incomplete) | peer: model `early` in item 1 test | covered |
| 5 | provider_fixtures: usage per adapter | peer item 1 test (usage 7/3 once per dialect); provider tests below | covered |
| 6 | provider_fixtures: tool-call fixture per adapter | `tests/provider_behavior.d:Responses interleaves tool calls, deduplicates completion, and accepts absent usage`, `Messages retains cumulative usage and completes the tool only at block stop`, `Gemini waits for a finish reason and omits hidden thought parts`, `OpenRouter Chat accounts for its repeated terminal usage chunk only once`; peer model `toolcancel` (all five dialects) | covered, added (peer tool traces) |
| 7 | provider_fixtures: documented protocol date | Anthropic `2023-06-01` header and Gemini `v1beta` asserted by the peer; protocol references in `IMPLEMENTATION.md`. Fixtures carry no separate per-record date stamp | covered (partial: no per-fixture date field) |
| 8 | sse_split: every byte split of UTF-8, CRLF, comments, multiline data | `tests/sse_behavior.d:all byte splits preserve CRLF, UTF-8 and joined data`; `every two-cut fragmentation of mixed terminators and long lines matches the whole stream`; `the line limit is exact whether a line arrives whole or across fragments` | covered |
| 9 | tool_arguments: interleaved two-call deltas assemble by ID | `tests/provider_behavior.d:Responses interleaves tool calls, ...` | covered |
| 10 | tool_arguments: incomplete/malformed JSON never invokes or emits a tool | `tests/provider_behavior.d:tool_arguments: malformed, mismatched or unfinished arguments never produce a tool event` (Responses malformed / mismatched final / non-object, Messages open JSON at block stop, Chat Completions open JSON at finish, EOF before done); `tests/tools_behavior.d:only explicit dispatch ...` (partial JSON dispatch refused) | added, covered |
| 11 | tool_authorization: model-emitted destructive tool name alone causes no execution | `tests/tools_behavior.d:tool_authorization: a model-emitted destructive call is only an event until the app dispatches it` (event delivered, invoked 0; denying policy and cancelled Context keep invoked 0; explicit dispatch invokes once) | added |
| 12 | tool_authorization: only explicit dispatcher with policy invokes | `tests/tools_behavior.d:only explicit dispatch of valid authorized arguments invokes the registered tool` | covered |
| 13 | limits: event byte 1048577 | `tests/sse_behavior.d:exact one-mebibyte data with BOM passes and the next byte fails` | covered |
| 14 | limits: tool round 9 | peer item 1 test (`toolRounds = 9` and `maxToolRounds = 9` -> resourceExhausted) | covered, added (`maxToolRounds = 9`) |
| 15 | limits: concurrent request 33 | `tests/client_behavior.d:provider configuration rejects plaintext and mismatched options` (33 refused at open); peer item 1 test (re-entrant stream with every workspace leased -> resourceExhausted). A 33rd in-flight request against 32 leased workspaces is not driven; the same `acquire` path is exercised at 1+1 | covered (partial) |
| 16 | limits: 1 MiB total tool arguments, 16 calls per request | `tests/provider_behavior.d:limits: tool arguments cap at 1 MiB across calls and 16 concurrent calls per request` | added |
| 17 | usage_accounting: cumulative usage not double-counted | `Messages retains cumulative usage ...` (3 then 6 reports 6) | covered |
| 18 | usage_accounting: OpenRouter Chat repeated terminal usage chunk emits one completion | `OpenRouter Chat accounts for its repeated terminal usage chunk only once` | covered |
| 19 | cancel_no_replay: cancel after text delta, request closed, not replayed | peer item 1 test (model `cancel`; peer asserts one POST and tolerates only that retirement) | covered |
| 20 | cancel_no_replay: cancel after a tool side effect | peer: `cancelAfterTool` in `tests/client_behavior.d` (model `toolcancel`, all five dialects; peer asserts exactly one POST each) | added |
| 21 | schema_negative: pointer, delegate, cyclic DTO fail compile with named field path | `negative/check.py`: `pointer_schema.d` (`PointerArgument.cursor`), `delegate_schema.d` (`CallableArgument.routine`), `cyclic_schema.d` (`NodeArgument.next`), `slice_cycle_schema.d` (`TreeArgument.children`) | covered (runner added), added (slice cycle) |
| 22 | Duplicate tool names fail deterministically (section 4) | `negative/check.py`: `duplicate_tools.d` ("duplicate names in the tool registry"); unknown tool -> notFound in item 12 test | added |
| 23 | Refusal is never a completed DTO | `Responses refusal never produces a completed event` | covered |
| 24 | ai_parser_bench: 100 MiB of 64-byte SSE deltas, bounded scratch, no D allocations | `bench/harness/replay.d` probes (IMPLEMENTATION.md records zero GC allocations in the timed region) | covered (not rerun in this review) |
| 25 | Fuzz seeds: truncated input, maximum lengths, empty values | `incomplete events, overflow and consumer cancellation stay terminal`; items 8, 13, 16 | covered |
| 26 | Fuzz seeds: cancellation, generation reuse | items 19-20; `tests/client_behavior.d:client_state: closed and stale copies refuse streams without a network request` | covered, added |
| 27 | Default options are usable (contract `temperature = 0`) | `tests/client_behavior.d:regression: default ChatOptions encode a request because temperature defaults to 0, not NaN` | fixed |

## Bugs fixed

- `source/flint/engine/ai/types.d`: `ChatOptions.temperature` had no initializer, so it defaulted to NaN
  instead of the contract's `0`. `checkOptions` rejects NaN, so every request built from default
  `ChatOptions` failed with `invalidArgument` ("invalid model, token budget or temperature") before
  sending. Existing tests always set 0.25 and masked it. Regression:
  `tests/client_behavior.d:regression: default ChatOptions encode a request because temperature
  defaults to 0, not NaN` (also exercised by `client_state`, which failed first).

## Stub review

No always-success or ignored-input paths found beyond the fixed default. All `ChatOptions` and
`AiOptions` fields reach validation or the encoded request.

## Verification (this review)

- `rtest acc-cloud ai both`: DMD rc=0, LDC rc=0; each linked binary under `tests/local_peer.py`: rc=0 ("Verified 30 scoped POSTs ... zero cancelled-request replays").
- `negative/check.py dmd ldc2`: 5/5 rejected on each compiler.
- `tools/gates.py --package ai --gate structural`: rc=0. `tools/quality.py --path packages/engine-ai`: 0 issues.
