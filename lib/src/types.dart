import 'dart:async';

/// What to ask: the same for every provider.
class LlmRequest {
  /// Creates a request.
  const LlmRequest({
    required this.system,
    required this.prompt,
    this.schema,
    this.maxTokens,
  });

  /// Instructions for the model: its role and rules.
  final String system;

  /// The user's input.
  final String prompt;

  /// JSON Schema the reply must follow, or null for plain text.
  final Map<String, Object?>? schema;

  /// Upper limit on reply tokens; null leaves it to the provider.
  final int? maxTokens;
}

/// One HTTP call a provider wants made. Providers describe the call;
/// the client sends it, so retries, timeouts and cancellation behave the
/// same everywhere.
class HttpCall {
  /// Creates a call description.
  const HttpCall({
    required this.url,
    required this.headers,
    required this.body,
  });

  /// Where to POST.
  final Uri url;

  /// Headers, including the key.
  final Map<String, String> headers;

  /// Encoded as JSON before sending.
  final Map<String, Object?> body;
}

/// A successful reply, before any JSON decoding.
class LlmReply {
  /// Creates a reply.
  const LlmReply(this.text, {this.usage});

  /// The reply text, JSON when a schema was given.
  final String text;

  /// Token counts, when the provider sends them.
  final Usage? usage;
}

/// Tokens used by one request, when the provider reports them.
class Usage {
  /// Creates a token count.
  const Usage({required this.input, required this.output});

  /// Tokens in the request.
  final int input;

  /// Tokens in the reply.
  final int output;

  @override
  String toString() => 'Usage(input: $input, output: $output)';
}

/// The answer and how it was obtained.
class LlmResult<T> {
  /// Creates a result.
  const LlmResult({
    required this.value,
    required this.model,
    required this.attempts,
    this.usage,
  });

  /// The decoded answer.
  final T value;

  /// The model that answered.
  final String model;

  /// HTTP requests sent, counting retries and fallbacks.
  final int attempts;

  /// Tokens used by the successful request, when reported.
  final Usage? usage;
}

/// One HTTP request, reported to `LlmClient.onAttempt`.
class LlmAttempt {
  /// Creates an attempt record.
  const LlmAttempt({
    required this.model,
    required this.number,
    required this.elapsed,
    this.statusCode,
    this.error,
  });

  /// The model that was called.
  final String model;

  /// 1 for the first request of the call, 2 for the next, and so on.
  final int number;

  /// How long the request took.
  final Duration elapsed;

  /// The HTTP status, or null when no response arrived.
  final int? statusCode;

  /// The exception thrown, when no response arrived.
  final Object? error;
}

/// How often to retry when the servers are busy (HTTP 5xx), before moving
/// on to the next model.
class RetryPolicy {
  /// Creates a policy.
  const RetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(seconds: 4),
  }) : assert(maxAttempts >= 1);

  /// No retries: each model is tried once.
  static const none = RetryPolicy(maxAttempts: 1);

  /// Requests per model, the first included.
  final int maxAttempts;

  /// Wait before the first retry; doubles for each later one.
  final Duration baseDelay;

  /// The wait before retry number [retry] (1 for the first retry).
  Duration delayBefore(int retry) => baseDelay * (1 << (retry - 1));
}

/// Lets a caller stop a request that is no longer needed, such as when
/// the user leaves the screen.
class CancelToken {
  final _cancelled = Completer<void>();

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _cancelled.future;

  /// Stops the request. Safe to call more than once.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
