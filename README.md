# byok_llm

[![CI](https://github.com/santisky8/byok_llm/actions/workflows/ci.yml/badge.svg)](https://github.com/santisky8/byok_llm/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/byok_llm.svg)](https://pub.dev/packages/byok_llm)

Typed JSON replies from LLMs, using the user's own API key ("bring your own key").

`byok_llm` is for apps whose users paste their own key for Gemini, Claude, OpenAI, Groq, OpenRouter, Mistral or any other OpenAI-compatible service. You make one call and get back a typed value. Free tiers run out often, models get retired and servers get busy, so the client tries the next model in your list before it gives up. When everything fails, the error is a sealed type, and the compiler makes you handle each case.

It is pure Dart with one dependency (`package:http`), so it works in Flutter on every platform, on the server and in the CLI.

## Install

```sh
dart pub add byok_llm
```

## Quick start

```dart
import 'package:byok_llm/byok_llm.dart';

final client = LlmClient(provider: const Gemini(), apiKey: userKey);

final result = await client.askJson(
  system: 'Break the goal into small steps.',
  prompt: 'Run a 10k',
  schema: {
    'type': 'object',
    'required': ['steps'],
    'properties': {
      'steps': {'type': 'array', 'items': {'type': 'string'}},
    },
  },
  decode: (json) => ((json as Map)['steps'] as List).cast<String>(),
);

print(result.value);    // [Buy running shoes, Run 2 km, ...]
print(result.model);    // the model that answered
print(result.attempts); // HTTP requests, counting retries and fallbacks
print(result.usage);    // Usage(input: 41, output: 12), when reported
```

`decode` gets the parsed JSON, which is a map or a list. If it throws, you get `InvalidReply`, and the raw text stays available for logging.

## Providers

| Provider | Constructor | Schema |
|---|---|---|
| Google Gemini | `Gemini()` | enforced by the service |
| Anthropic Claude | `Anthropic()` | sent in the system prompt |
| OpenAI | `OpenAiCompatible.openAi()` | sent in the system prompt, JSON mode on |
| Groq | `OpenAiCompatible.groq()` | sent in the system prompt, JSON mode on |
| OpenRouter | `OpenAiCompatible.openRouter(appName: 'My App')` | sent in the system prompt, JSON mode on |
| Mistral | `OpenAiCompatible.mistral()` | sent in the system prompt, JSON mode on |
| Anything else that speaks OpenAI's format | `OpenAiCompatible(name:, baseUrl:, models:)` | sent in the system prompt, JSON mode on |

Each provider has a default model list, and you can pass your own. The client tries the models in order:

```dart
const Gemini(models: ['gemini-3.5-flash-lite', 'gemini-3.5-flash'])
```

Models also send JSON wrapped in code fences or surrounded by words. `decodeJsonReply` handles both.

## Errors

Every failure is a subclass of the sealed `LlmException`:

```dart
try {
  final result = await client.askJson(/* ... */);
} on LlmException catch (e) {
  final message = switch (e) {
    RateLimited(:final retryAfter) => 'Free limit reached. Try again ${retryAfter == null ? 'later' : 'in ${retryAfter.inSeconds}s'}.',
    ProviderBusy() => 'The service is busy. Try again in a minute.',
    InvalidKey() => 'Check your API key.',
    ModelUnavailable() => 'None of these models exist any more.',
    Truncated() => 'The answer was too long.',
    Blocked(:final reason) => 'The service would not answer ($reason).',
    InvalidReply() => 'The answer was not in the expected shape.',
    RequestFailed(:final statusCode) => 'Request rejected ($statusCode).',
    LlmTimeout() || ConnectionFailed() => 'No connection.',
    Cancelled() => '',
  };
}
```

`e.retryable` is true for `RateLimited`, `ProviderBusy`, `LlmTimeout` and `ConnectionFailed`.

## What happens on each failure

| Reply | What the client does |
|---|---|
| 200 | returns the answer |
| 429 rate limited | tries the next model at once, because each model has its own quota |
| 404, or a 400 that names a retired model | tries the next model |
| 5xx busy | retries the same model with backoff (`RetryPolicy`), then tries the next model |
| 401 / 402 / 403, or Gemini's 400 `API_KEY_INVALID` | throws `InvalidKey` at once, because the key is wrong for every model |
| any other 4xx | throws `RequestFailed` at once |

When every model fails, the most useful reason wins: `RateLimited`, then `ProviderBusy`, then `ModelUnavailable`.

```dart
LlmClient(
  provider: const OpenAiCompatible.groq(),
  apiKey: key,
  retry: const RetryPolicy(maxAttempts: 3, baseDelay: Duration(seconds: 4)),
  timeout: const Duration(seconds: 60), // per HTTP request
  onAttempt: (a) => log('${a.model} #${a.number}: ${a.statusCode} in ${a.elapsed}'),
);
```

## Cancelling

```dart
final cancel = CancelToken();
final future = client.askJson(/* ... */, cancel: cancel);
// The user left the screen:
cancel.cancel(); // the request is aborted and the future throws Cancelled
```

## Adding a provider

Implement `LlmProvider`. You describe the HTTP call and read the reply. The client handles retries, fallback, timeouts, cancellation and error mapping.

```dart
class MyProvider implements LlmProvider {
  @override
  String get name => 'My service';

  @override
  List<String> get models => const ['my-model'];

  @override
  HttpCall buildCall(LlmRequest request, {required String model, required String apiKey}) =>
      HttpCall(
        url: Uri.parse('https://api.example.com/generate'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $apiKey'},
        body: {
          'model': model,
          'system': schemaInstructions(request.system, request.schema),
          'input': request.prompt,
        },
      );

  @override
  LlmReply parseReply(Map<String, Object?> body) => LlmReply(body['output'] as String);
}
```

## Testing your app

Pass a `MockClient` from `package:http/testing.dart`:

```dart
final client = LlmClient(
  provider: const Gemini(),
  apiKey: 'test',
  retry: RetryPolicy.none,
  httpClient: MockClient((request) async => http.Response(cannedGeminiReply, 200)),
);
```

This package's own tests use recorded replies from each service in [`test/fixtures`](test/fixtures).

## Not yet supported

- Streaming
- Images and other non-text input
- Tool or function calling

## License

MIT
