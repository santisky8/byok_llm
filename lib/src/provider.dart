import 'dart:convert';

import 'errors.dart';
import 'types.dart';

/// An LLM service: how to call it and how to read its reply.
///
/// The built-in providers are [Gemini], [Anthropic] and
/// [OpenAiCompatible]. Implement this interface to add another service;
/// the client takes care of retries, fallback, timeouts and errors.
abstract interface class LlmProvider {
  /// The service's name, used in error messages.
  String get name;

  /// Tried in order: when one is rate limited, busy or retired, the next
  /// takes over. Must not be empty.
  List<String> get models;

  /// The HTTP call that sends [request] to [model].
  HttpCall buildCall(
    LlmRequest request, {
    required String model,
    required String apiKey,
  });

  /// Reads a successful (HTTP 200) reply. Throws [Truncated] or [Blocked]
  /// when the service did not finish its answer.
  LlmReply parseReply(Map<String, Object?> body);
}

/// [system] followed by an instruction to reply with JSON that follows
/// [schema], for services that cannot enforce a schema themselves.
String schemaInstructions(String system, Map<String, Object?>? schema) =>
    schema == null
    ? system
    : '$system\n\nReply with only a JSON object that follows this JSON '
          'Schema:\n${jsonEncode(schema)}';

/// Google Gemini, with the reply schema enforced by the service.
class Gemini implements LlmProvider {
  /// Gemini with [models] tried in order, cheapest first by default.
  const Gemini({
    this.models = const [
      'gemini-3.5-flash-lite',
      'gemini-3.1-flash-lite',
      'gemini-3.5-flash',
    ],
    this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta',
  });

  @override
  String get name => 'Google Gemini';

  @override
  final List<String> models;

  /// The API address before `/models`; change it for a proxy.
  final String baseUrl;

  @override
  HttpCall buildCall(
    LlmRequest request, {
    required String model,
    required String apiKey,
  }) => HttpCall(
    url: Uri.parse('$baseUrl/models/$model:generateContent'),
    headers: {'content-type': 'application/json', 'x-goog-api-key': apiKey},
    body: {
      'systemInstruction': {
        'parts': [
          {'text': request.system},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': request.prompt},
          ],
        },
      ],
      'generationConfig': {
        if (request.schema != null) ...{
          'responseMimeType': 'application/json',
          'responseJsonSchema': request.schema,
        },
        if (request.maxTokens != null) 'maxOutputTokens': request.maxTokens,
      },
    },
  );

  @override
  LlmReply parseReply(Map<String, Object?> body) {
    final candidates = body['candidates'] as List?;
    final candidate = candidates == null || candidates.isEmpty
        ? null
        : candidates.first as Map;
    final finish = candidate?['finishReason'] as String?;
    if (finish == 'MAX_TOKENS') {
      throw Truncated('$name did not finish (too long).');
    }
    if (candidate == null || finish != 'STOP') {
      final reason =
          finish ??
          (body['promptFeedback'] as Map?)?['blockReason'] as String? ??
          'BLOCKED';
      throw Blocked('$name did not finish ($reason).', reason: reason);
    }
    final parts = (candidate['content'] as Map)['parts'] as List;
    final usage = body['usageMetadata'] as Map?;
    return LlmReply(
      parts.map((p) => (p as Map)['text'] ?? '').join(),
      usage: usage == null
          ? null
          : Usage(
              input: (usage['promptTokenCount'] as num?)?.toInt() ?? 0,
              output: (usage['candidatesTokenCount'] as num?)?.toInt() ?? 0,
            ),
    );
  }
}

/// Anthropic's Claude, through the Messages API.
class Anthropic implements LlmProvider {
  /// Claude with [models] tried in order.
  const Anthropic({
    this.models = const ['claude-haiku-4-5'],
    this.baseUrl = 'https://api.anthropic.com/v1',
    this.defaultMaxTokens = 16000,
  });

  @override
  String get name => 'Anthropic (Claude)';

  @override
  final List<String> models;

  /// The API address before `/messages`; change it for a proxy.
  final String baseUrl;

  /// Sent when the request sets no limit: the API requires one.
  final int defaultMaxTokens;

  @override
  HttpCall buildCall(
    LlmRequest request, {
    required String model,
    required String apiKey,
  }) => HttpCall(
    url: Uri.parse('$baseUrl/messages'),
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: {
      'model': model,
      'max_tokens': request.maxTokens ?? defaultMaxTokens,
      'system': schemaInstructions(request.system, request.schema),
      'messages': [
        {'role': 'user', 'content': request.prompt},
      ],
    },
  );

  @override
  LlmReply parseReply(Map<String, Object?> body) {
    final stop = body['stop_reason'];
    if (stop == 'max_tokens') {
      throw Truncated('$name did not finish (too long).');
    }
    if (stop == 'refusal') {
      throw Blocked('$name would not answer.', reason: 'refusal');
    }
    final usage = body['usage'] as Map?;
    return LlmReply(
      (body['content'] as List)
          .map((p) => (p as Map)['type'] == 'text' ? p['text'] : '')
          .join(),
      usage: usage == null
          ? null
          : Usage(
              input: (usage['input_tokens'] as num?)?.toInt() ?? 0,
              output: (usage['output_tokens'] as num?)?.toInt() ?? 0,
            ),
    );
  }
}

/// Any service that speaks OpenAI's chat completions format. Named
/// constructors cover the common ones.
class OpenAiCompatible implements LlmProvider {
  /// Any OpenAI-compatible service at [baseUrl].
  const OpenAiCompatible({
    required this.name,
    required this.baseUrl,
    required this.models,
    this.headers = const {},
    this.maxTokensField = 'max_tokens',
  });

  /// OpenAI. Its newer models need `max_completion_tokens`.
  const OpenAiCompatible.openAi({
    List<String> models = const ['gpt-5-mini', 'gpt-4.1-mini'],
  }) : this(
         name: 'OpenAI',
         baseUrl: 'https://api.openai.com/v1',
         models: models,
         maxTokensField: 'max_completion_tokens',
       );

  /// Groq, which has a free tier.
  const OpenAiCompatible.groq({
    List<String> models = const [
      'openai/gpt-oss-120b',
      'llama-3.3-70b-versatile',
    ],
  }) : this(
         name: 'Groq',
         baseUrl: 'https://api.groq.com/openai/v1',
         models: models,
       );

  /// [appName] is shown on the user's OpenRouter activity page.
  OpenAiCompatible.openRouter({
    String? appName,
    List<String> models = const [
      'meta-llama/llama-3.3-70b-instruct:free',
      'openai/gpt-oss-20b:free',
      'deepseek/deepseek-chat-v3.1:free',
    ],
  }) : this(
         name: 'OpenRouter',
         baseUrl: 'https://openrouter.ai/api/v1',
         models: models,
         headers: {'x-title': ?appName},
       );

  /// Mistral, whose free "Experiment" plan works.
  const OpenAiCompatible.mistral({
    List<String> models = const ['mistral-small-latest'],
  }) : this(
         name: 'Mistral',
         baseUrl: 'https://api.mistral.ai/v1',
         models: models,
       );

  /// Demon Route: open-weight, abliterated and community fine-tuned
  /// models behind one OpenAI-compatible key. Full list at
  /// https://demonroute.com/models.
  const OpenAiCompatible.demonRoute({
    List<String> models = const [
      'huihui-ai/Huihui-gemma-4-31B-it-abliterated-v2',
      'TheDrummer/Cydonia-24B-v4.1',
    ],
  }) : this(
         name: 'Demon Route',
         baseUrl: 'https://api.demonroute.com/v1',
         models: models,
       );

  @override
  final String name;

  /// The address before `/chat/completions`.
  final String baseUrl;

  @override
  final List<String> models;

  /// Extra headers sent with every request.
  final Map<String, String> headers;

  /// `max_tokens` for most services; OpenAI's newer models need
  /// `max_completion_tokens`.
  final String maxTokensField;

  @override
  HttpCall buildCall(
    LlmRequest request, {
    required String model,
    required String apiKey,
  }) => HttpCall(
    url: Uri.parse('$baseUrl/chat/completions'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer $apiKey',
      ...headers,
    },
    body: {
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': schemaInstructions(request.system, request.schema),
        },
        {'role': 'user', 'content': request.prompt},
      ],
      if (request.schema != null) 'response_format': {'type': 'json_object'},
      if (request.maxTokens != null) maxTokensField: request.maxTokens,
    },
  );

  @override
  LlmReply parseReply(Map<String, Object?> body) {
    final choice = (body['choices'] as List).first as Map;
    final finish = choice['finish_reason'];
    if (finish == 'length') {
      throw Truncated('$name did not finish (too long).');
    }
    if (finish == 'content_filter') {
      throw Blocked('$name would not answer.', reason: 'content_filter');
    }
    final usage = body['usage'] as Map?;
    return LlmReply(
      (choice['message'] as Map)['content'] as String? ?? '',
      usage: usage == null
          ? null
          : Usage(
              input: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
              output: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
            ),
    );
  }
}
