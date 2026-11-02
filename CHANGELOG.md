## Unreleased

- `OpenAiCompatible.demonRoute()` preset for Demon Route.

## 0.1.0

First release.

- `LlmClient` with `askJson<T>` (typed JSON replies) and `generate` (text).
- Providers: `Gemini`, `Anthropic`, and `OpenAiCompatible` with presets for OpenAI, Groq, OpenRouter and Mistral. Implement `LlmProvider` to add others.
- Falls back across the models of a provider when one is rate limited, retired or busy. Busy servers are retried with `RetryPolicy` backoff.
- Sealed `LlmException` hierarchy: `RateLimited` (with `retryAfter`), `ProviderBusy`, `InvalidKey`, `ModelUnavailable`, `Truncated`, `Blocked`, `InvalidReply`, `RequestFailed`, `LlmTimeout`, `ConnectionFailed`, `Cancelled`.
- Per-request timeout, `CancelToken` that aborts the HTTP request, `onAttempt` hook and token `Usage` in results.
- `decodeJsonReply` reads JSON wrapped in code fences or surrounded by words.
