/// Why a request to an LLM failed.
///
/// The class is sealed, so a `switch` over it is checked by the compiler:
///
/// ```dart
/// try {
///   await client.askJson(...);
/// } on LlmException catch (e) {
///   final text = switch (e) {
///     RateLimited() => 'Limit reached, try again soon.',
///     ProviderBusy() => 'The service is busy.',
///     InvalidKey() => 'Check your API key.',
///     _ => 'Could not answer: $e',
///   };
/// }
/// ```
sealed class LlmException implements Exception {
  const LlmException(this.message);

  /// A short description, safe to show to the user.
  final String message;

  /// Whether trying the same request again later can succeed.
  bool get retryable => false;

  @override
  String toString() => message;
}

/// The key's quota is used up on every model tried (HTTP 429).
final class RateLimited extends LlmException {
  /// Creates the error; [retryAfter] comes from the Retry-After header.
  const RateLimited(super.message, {this.retryAfter});

  /// How long the service asked to wait, when it said so.
  final Duration? retryAfter;

  @override
  bool get retryable => true;
}

/// The service's servers are overloaded or failing (HTTP 5xx).
final class ProviderBusy extends LlmException {
  /// Creates the error for HTTP [statusCode].
  const ProviderBusy(super.message, {required this.statusCode});

  /// The HTTP status of the last busy reply.
  final int statusCode;

  @override
  bool get retryable => true;
}

/// The service refused the key: wrong, deleted or out of credit
/// (HTTP 401, 402 or 403).
final class InvalidKey extends LlmException {
  /// Creates the error for HTTP [statusCode].
  const InvalidKey(super.message, {required this.statusCode});

  /// The HTTP status that refused the key.
  final int statusCode;
}

/// No model in the provider's list exists any more, or the key cannot
/// use any of them.
final class ModelUnavailable extends LlmException {
  /// Creates the error for the [models] that were tried.
  const ModelUnavailable(super.message, {required this.models});

  /// The models that were tried.
  final List<String> models;
}

/// The reply stopped at the token limit before it was complete.
final class Truncated extends LlmException {
  /// Creates the error.
  const Truncated(super.message);
}

/// The service would not answer, for example for safety reasons.
final class Blocked extends LlmException {
  /// Creates the error with the service's [reason].
  const Blocked(super.message, {required this.reason});

  /// The service's own reason, such as `SAFETY` or `RECITATION`.
  final String reason;
}

/// A reply arrived but could not be used: not JSON, or not the expected
/// shape. Decoders passed to `askJson` may throw it too.
final class InvalidReply extends LlmException {
  /// Creates the error; [raw] is the reply text, when there was one.
  const InvalidReply(super.message, {this.raw});

  /// The text the service sent back, when there was one.
  final String? raw;
}

/// The service rejected the request for another reason (any other 4xx).
final class RequestFailed extends LlmException {
  /// Creates the error for HTTP [statusCode].
  const RequestFailed(super.message, {required this.statusCode});

  /// The HTTP status of the rejected request.
  final int statusCode;
}

/// No answer within the client's timeout.
final class LlmTimeout extends LlmException {
  /// Creates the error.
  const LlmTimeout(super.message);

  @override
  bool get retryable => true;
}

/// The service could not be reached (no network, DNS or TLS failure).
final class ConnectionFailed extends LlmException {
  /// Creates the error; [cause] is the underlying exception.
  const ConnectionFailed(super.message, {this.cause});

  /// The underlying exception, such as an `http.ClientException`.
  final Object? cause;

  @override
  bool get retryable => true;
}

/// The caller cancelled the request with a `CancelToken`.
final class Cancelled extends LlmException {
  /// Creates the error.
  const Cancelled() : super('Cancelled');
}
