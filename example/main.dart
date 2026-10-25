// Splits a goal into steps with the key in GEMINI_API_KEY:
//
//   GEMINI_API_KEY=... dart run example/main.dart "Run a 10k"
import 'dart:io';

import 'package:byok_llm/byok_llm.dart';

Future<void> main(List<String> args) async {
  final key = Platform.environment['GEMINI_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('Set GEMINI_API_KEY first.');
    exit(64);
  }
  final goal = args.isEmpty ? 'Run a 10k' : args.join(' ');

  final client = LlmClient(
    provider: const Gemini(),
    apiKey: key,
    onAttempt: (a) => stderr.writeln(
      '${a.model} #${a.number}: ${a.statusCode ?? a.error} '
      'in ${a.elapsed.inMilliseconds} ms',
    ),
  );

  try {
    final result = await client.askJson(
      system: 'Break the goal into 3 to 6 small, concrete steps.',
      prompt: goal,
      schema: const {
        'type': 'object',
        'required': ['steps'],
        'properties': {
          'steps': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
      },
      decode: (json) => ((json as Map)['steps'] as List).cast<String>(),
    );
    for (final (i, step) in result.value.indexed) {
      print('${i + 1}. $step');
    }
    print('\n${result.model}, ${result.usage ?? 'no usage reported'}');
  } on LlmException catch (e) {
    stderr.writeln(switch (e) {
      InvalidKey() => 'Gemini refused the key.',
      RateLimited() => 'Free limit reached; try again later.',
      _ => 'Failed: $e',
    });
    exitCode = 1;
  } finally {
    client.close();
  }
}
