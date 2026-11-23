# Streaming chat and typed tools

`ChatClient.open` takes an explicit provider, operator-owned origin and API key. Supply the API version for Anthropic Messages and Gemini. Set the model on each request. OpenRouter uses Responses by default and switches to Chat Completions when explicitly configured. It requires the selected provider to support the fields it forwards. Bring a PEM bundle for a private HTTPS origin. Plain HTTP is available on explicitly enabled numeric loopback for tests.

Each client has one owner thread and up to 32 concurrent request workspaces. It reserves the configured request and event storage at startup. `stream` borrows the upload until libcurl retires it. It accepts up to 128 conversation messages, 16 advertised tools, eight tool rounds, 1 MiB per event, 1 MiB of assembled tool arguments, and 16 MiB of decoded response bytes. The SSE parser retains split UTF-8 and line fragments and joins multiline data. Set a Context deadline for each request.

The transport retries an explicit prestream 429, 502, 503 or 529 within the configured retry budget, capped at three. Each attempt has a fresh request identity and a short backoff bounded by the Context. A delivered event or an ambiguous transport failure ends automatic replay. Failure events distinguish provider errors, refusal, incomplete output and cancellation. Usage, when present, is emitted once. Completion requires the provider's terminal event or, for Gemini, an explicit finish reason followed by EOF.

Tool events contain validated complete JSON objects. Copy `text`, `providerCallId`, `toolName`, and any `providerState` you intend to retain before the callback returns. `toolCallId` on a received event is a bounded per-request routing label. Use `providerCallId` for continuations and include the actual provider ID when `providerAssignedId` is true. Gemini can attach an opaque thought signature to an assistant tool call. Return that value unchanged as `ChatMessage.providerState` on the corresponding call. The app chooses whether to dispatch, checks authorization, and records idempotency. Supply a `ToolMethods` tuple to publish typed schemas and use `dispatchTool` explicitly.

## Linux verification

Run the real transport tests against the local fixture after pinning the HTTP providers.

```sh
python3 tools/native_build.py --profile http --target linux-x86_64-glibc --phase build --emit-dub
python3 engine/ai/tests/local_peer.py dub test :ai --compiler=dmd
python3 engine/ai/tests/local_peer.py dub test :ai --compiler=ldc2
python3 tools/gates.py --package ai --gate structural
```

The five loopback dialects verify request paths, authentication headers, model options, request identity rotation, sanitized failure status and no cancellation replay. Event fixtures cover interleaved calls, missing usage, cumulative usage, repeated completion and refusal handling. Both compilers reject pointer, delegate and cyclic tool DTO fields with the field name in the diagnostic. LDC ASan with leak checking exercised the loopback fixtures. The O3 and Oz probes replay a 100 MiB sequence of 64-byte SSE records with identical byte counts and zero measured D GC allocations in the timed region. The largest observed stripped wrapper delta was 28,640 bytes. Release performance certification remains open.

[OpenAI Responses events](https://developers.openai.com/api/reference/resources/responses/streaming-events), [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming), [Gemini generation](https://aistudio.google.com/api-reference/generate-content), [OpenRouter streaming](https://openrouter.ai/docs/api_reference/streaming).
