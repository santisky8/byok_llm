/// Typed JSON replies from LLMs with the user's own API key.
///
/// ```dart
/// final client = LlmClient(provider: const Gemini(), apiKey: key);
/// final result = await client.askJson(
///   system: 'Split the goal into steps.',
///   prompt: 'Run a 10k',
///   schema: {'type': 'object', 'properties': {'steps': {'type': 'array'}}},
///   decode: (json) => (json as Map)['steps'] as List,
/// );
/// print('${result.value} from ${result.model}');
/// ```
library;

export 'src/client.dart';
export 'src/errors.dart';
export 'src/json.dart' show decodeJsonReply;
export 'src/provider.dart';
export 'src/types.dart';
