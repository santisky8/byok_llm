import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:byok_llm/byok_llm.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response reply(String name, [int code = 200]) =>
    http.Response(fixture(name), code);

const schema = {
  'type': 'object',
  'required': ['steps'],
  'properties': {
    'steps': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
};

List<String> steps(Object? json) =>
    ((json as Map)['steps'] as List).cast<String>();

/// A client that answers each request with the next of [responses] and
/// records what was sent.
({LlmClient client, List<http.Request> sent}) fake(
  LlmProvider provider,
  List<http.Response> responses, {
  RetryPolicy retry = const RetryPolicy(baseDelay: Duration.zero),
  Duration timeout = const Duration(seconds: 5),
  void Function(LlmAttempt)? onAttempt,
}) {
  final sent = <http.Request>[];
  final client = LlmClient(
    provider: provider,
    apiKey: 'k',
    retry: retry,
    timeout: timeout,
    onAttempt: onAttempt,
    httpClient: MockClient((r) async {
      sent.add(r);
      return responses[sent.length - 1];
    }),
  );
  return (client: client, sent: sent);
}

Future<LlmResult<List<String>>> ask(LlmClient client, {CancelToken? cancel}) =>
    client.askJson(
      system: 'Split the goal.',
      prompt: 'Run a 10k',
      schema: schema,
      decode: steps,
      cancel: cancel,
    );

void main() {
  group('providers', () {
    test('Gemini sends the schema natively and reads usage', () async {
      final f = fake(const Gemini(models: ['g1']), [reply('gemini-ok.json')]);
      final result = await ask(f.client);

      final sent = f.sent.single;
      expect(
        sent.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/g1:generateContent',
      );
      expect(sent.headers['x-goog-api-key'], 'k');
      final body = jsonDecode(sent.body) as Map;
      expect(body['generationConfig']['responseJsonSchema'], schema);
      expect(result.value, ['Buy shoes', 'Run 2 km']);
      expect(result.model, 'g1');
      expect(result.usage?.input, 41);
      expect(result.usage?.output, 12);
    });

    test('Anthropic puts the schema in the system prompt and reads a '
        'fenced reply', () async {
      final f = fake(const Anthropic(), [reply('anthropic-ok.json')]);
      final result = await ask(f.client);

      final body = jsonDecode(f.sent.single.body) as Map;
      expect(f.sent.single.headers['x-api-key'], 'k');
      expect(body['max_tokens'], 16000);
      expect(body['system'], contains('JSON Schema'));
      expect(result.value, ['Buy shoes', 'Run 2 km']);
      expect(result.usage?.output, 19);
    });

    test(
      'OpenAI-compatible presets use their own address and fields',
      () async {
        final groq = fake(const OpenAiCompatible.groq(), [
          reply('openai-ok.json'),
        ]);
        final result = await ask(groq.client);
        expect(
          groq.sent.single.url.toString(),
          'https://api.groq.com/openai/v1/chat/completions',
        );
        expect(groq.sent.single.headers['authorization'], 'Bearer k');
        // Words around the JSON are dropped.
        expect(result.value, ['Buy shoes', 'Run 2 km']);

        final router = fake(OpenAiCompatible.openRouter(appName: 'My App'), [
          reply('openai-ok.json'),
        ]);
        await ask(router.client);
        expect(router.sent.single.headers['x-title'], 'My App');

        final openAi = fake(const OpenAiCompatible.openAi(), [
          reply('openai-ok.json'),
        ]);
        await openAi.client.generate(system: 's', prompt: 'p', maxTokens: 50);
        final body = jsonDecode(openAi.sent.single.body) as Map;
        expect(body['max_completion_tokens'], 50);
        expect(body.containsKey('response_format'), isFalse);
      },
    );

    test('Demon Route preset uses its own address', () async {
      final f = fake(const OpenAiCompatible.demonRoute(), [
        reply('openai-ok.json'),
      ]);
      await ask(f.client);
      expect(
        f.sent.single.url.toString(),
        'https://api.demonroute.com/v1/chat/completions',
      );
      expect(f.sent.single.headers['authorization'], 'Bearer k');
      final body = jsonDecode(f.sent.single.body) as Map;
      expect(body['model'], 'huihui-ai/Huihui-gemma-4-31B-it-abliterated-v2');
    });

    test('OpenRouter without an app name sends no x-title', () async {
      final f = fake(OpenAiCompatible.openRouter(), [reply('openai-ok.json')]);
      await ask(f.client);
      expect(f.sent.single.headers.containsKey('x-title'), isFalse);
    });
  });

  group('fallback and retries', () {
    test('a rate-limited model hands over to the next one', () async {
      final f = fake(const Gemini(models: ['a', 'b']), [
        http.Response('{}', 429),
        reply('gemini-ok.json'),
      ]);
      final result = await ask(f.client);
      expect(result.model, 'b');
      expect(result.attempts, 2);
    });

    test('rate limits on every model are reported with Retry-After', () async {
      final f = fake(const Gemini(models: ['a', 'b']), [
        http.Response('{}', 429),
        http.Response('{}', 429, headers: {'retry-after': '30'}),
      ]);
      await expectLater(
        ask(f.client),
        throwsA(
          isA<RateLimited>()
              .having((e) => e.retryAfter, 'retryAfter', Duration(seconds: 30))
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('busy servers are retried, then the next model is tried', () async {
      final f = fake(const Gemini(models: ['a', 'b']), [
        http.Response('', 503),
        http.Response('', 503),
        http.Response('', 503),
        reply('gemini-ok.json'),
      ]);
      final result = await ask(f.client);
      expect(result.model, 'b');
      expect(result.attempts, 4);
    });

    test('busy on every model is ProviderBusy', () async {
      final f = fake(
        const Gemini(models: ['a', 'b']),
        List.filled(4, http.Response('', 500)),
        retry: const RetryPolicy(maxAttempts: 2, baseDelay: Duration.zero),
      );
      await expectLater(ask(f.client), throwsA(isA<ProviderBusy>()));
      expect(f.sent, hasLength(4));
    });

    test('a rate limit is reported over a later busy model', () async {
      final f = fake(const Gemini(models: ['a', 'b']), [
        http.Response('{}', 429),
        http.Response('', 503),
      ], retry: RetryPolicy.none);
      await expectLater(ask(f.client), throwsA(isA<RateLimited>()));
    });

    test('retired models are skipped: 404 or a 400 that says so', () async {
      final f = fake(const OpenAiCompatible.groq(models: ['a', 'b', 'c']), [
        http.Response('{"error":{"message":"not found"}}', 404),
        reply('error-400-retired-model.json', 400),
        reply('openai-ok.json'),
      ]);
      final result = await ask(f.client);
      expect(result.model, 'c');
    });

    test('every model retired is ModelUnavailable', () async {
      final f = fake(const Gemini(models: ['a', 'b']), [
        http.Response('', 404),
        http.Response('', 404),
      ]);
      await expectLater(
        ask(f.client),
        throwsA(
          isA<ModelUnavailable>().having((e) => e.models, 'models', ['a', 'b']),
        ),
      );
    });

    test('an ordinary 400 is not mistaken for a retired model', () async {
      final f = fake(const OpenAiCompatible.groq(models: ['a', 'b']), [
        reply('error-400-bad-request.json', 400),
      ]);
      await expectLater(
        ask(f.client),
        throwsA(
          isA<RequestFailed>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message, 'message', contains('at least one')),
        ),
      );
      expect(f.sent, hasLength(1));
    });

    test('onAttempt sees every request', () async {
      final seen = <LlmAttempt>[];
      final f = fake(const Gemini(models: ['a', 'b']), [
        http.Response('{}', 429),
        reply('gemini-ok.json'),
      ], onAttempt: seen.add);
      await ask(f.client);
      expect(seen.map((a) => (a.model, a.number, a.statusCode)), [
        ('a', 1, 429),
        ('b', 2, 200),
      ]);
    });
  });

  group('errors', () {
    test('a refused key with an HTML body is InvalidKey', () async {
      final f = fake(const Anthropic(models: ['a', 'b']), [
        reply('error-401-html.html', 401),
      ]);
      await expectLater(
        ask(f.client),
        throwsA(
          isA<InvalidKey>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
      // The key is wrong for every model: no point trying the next.
      expect(f.sent, hasLength(1));
    });

    test("Gemini's 400 for a wrong key is InvalidKey", () async {
      final f = fake(const Gemini(), [reply('gemini-400-bad-key.json', 400)]);
      await expectLater(
        ask(f.client),
        throwsA(
          isA<InvalidKey>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
      expect(f.sent, hasLength(1));
    });

    test('402 and 403 are InvalidKey too', () async {
      for (final code in [402, 403]) {
        final f = fake(const Gemini(), [http.Response('', code)]);
        await expectLater(ask(f.client), throwsA(isA<InvalidKey>()));
      }
    });

    test('truncated replies are Truncated', () async {
      for (final (provider, file) in [
        (const Anthropic() as LlmProvider, 'anthropic-max-tokens.json'),
        (const OpenAiCompatible.openAi(), 'openai-length.json'),
      ]) {
        final f = fake(provider, [reply(file)]);
        await expectLater(ask(f.client), throwsA(isA<Truncated>()));
      }
    });

    test('safety stops are Blocked with the reason', () async {
      for (final (file, reason) in [
        ('gemini-safety.json', 'SAFETY'),
        ('gemini-prompt-blocked.json', 'PROHIBITED_CONTENT'),
      ]) {
        final f = fake(const Gemini(), [reply(file)]);
        await expectLater(
          ask(f.client),
          throwsA(isA<Blocked>().having((e) => e.reason, 'reason', reason)),
        );
      }
    });

    test(
      'a reply that is not JSON is InvalidReply with the raw text',
      () async {
        final f = fake(const OpenAiCompatible.groq(), [
          http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'content': 'Sorry, I cannot help.'},
                },
              ],
            }),
            200,
          ),
        ]);
        await expectLater(
          ask(f.client),
          throwsA(
            isA<InvalidReply>().having(
              (e) => e.raw,
              'raw',
              'Sorry, I cannot help.',
            ),
          ),
        );
      },
    );

    test('a decoder that fails becomes InvalidReply', () async {
      final f = fake(const Gemini(), [reply('gemini-ok.json')]);
      await expectLater(
        f.client.askJson(
          system: 's',
          prompt: 'p',
          schema: schema,
          decode: (json) => (json as Map)['missing'] as String,
        ),
        throwsA(isA<InvalidReply>()),
      );
    });

    test('LlmExceptions thrown by a decoder pass through', () async {
      final f = fake(const Gemini(), [reply('gemini-ok.json')]);
      await expectLater(
        f.client.askJson(
          system: 's',
          prompt: 'p',
          schema: schema,
          decode: (_) => throw const InvalidReply('Nothing to show.'),
        ),
        throwsA(
          isA<InvalidReply>().having(
            (e) => e.message,
            'message',
            'Nothing to show.',
          ),
        ),
      );
    });

    test('a provider without models is rejected up front', () {
      expect(
        () => LlmClient(
          provider: const Gemini(models: []),
          apiKey: 'k',
        ),
        throwsArgumentError,
      );
    });

    test('no answer in time is LlmTimeout', () async {
      final client = LlmClient(
        provider: const Gemini(),
        apiKey: 'k',
        timeout: const Duration(milliseconds: 20),
        httpClient: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(ask(client), throwsA(isA<LlmTimeout>()));
    });

    test('a network failure is ConnectionFailed', () async {
      final client = LlmClient(
        provider: const Gemini(),
        apiKey: 'k',
        httpClient: MockClient((_) => throw http.ClientException('no route')),
      );
      await expectLater(ask(client), throwsA(isA<ConnectionFailed>()));
    });

    test('cancelling stops the request and the retries', () async {
      final cancel = CancelToken();
      var sent = 0;
      final client = LlmClient(
        provider: const Gemini(),
        apiKey: 'k',
        retry: const RetryPolicy(baseDelay: Duration(seconds: 30)),
        httpClient: MockClient((_) async {
          sent++;
          return http.Response('', 503);
        }),
      );
      final future = ask(client, cancel: cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.cancel();
      await expectLater(future, throwsA(isA<Cancelled>()));
      expect(sent, 1);
    });
  });

  group('decodeJsonReply', () {
    test('reads plain, fenced, wrapped and array JSON', () {
      expect(decodeJsonReply('{"a":1}'), {'a': 1});
      expect(decodeJsonReply('```json\n{"a":1}\n```'), {'a': 1});
      expect(decodeJsonReply('Sure! {"a":{"b":2}} Done.'), {
        'a': {'b': 2},
      });
      expect(decodeJsonReply('Here: [1, 2]'), [1, 2]);
    });

    test('throws FormatException when there is no JSON', () {
      expect(() => decodeJsonReply('no json {here'), throwsFormatException);
    });
  });
}
