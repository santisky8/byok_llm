import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'json.dart';
import 'provider.dart';
import 'types.dart';

/// Sends requests to one [LlmProvider] with the user's own [apiKey].
///
/// Each call tries the provider's models in order. A model that is rate
/// limited (429) or retired (404, or a 400 that says so) hands the request
/// to the next one at once; busy servers (5xx) are retried with
/// [RetryPolicy] before moving on. Failures are thrown as [LlmException]
/// subclasses.
class LlmClient {
  /// Creates a client. Pass [httpClient] to share connections or to test with a mock; otherwise the client makes its own and [close] closes it.
  LlmClient({
    required this.provider,
    required this.apiKey,
    this.retry = const RetryPolicy(),
    this.timeout = const Duration(seconds: 120),
    this.onAttempt,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null {
    if (provider.models.isEmpty) {
      throw ArgumentError.value(provider.name, 'provider', 'has no models');
    }
  }

  /// The service to call.
  final LlmProvider provider;

  /// The user's own key for [provider].
  final String apiKey;

  /// How busy servers (5xx) are retried before the next model is tried.
  final RetryPolicy retry;

  /// Per HTTP request, not per call.
  final Duration timeout;

  /// Called after every HTTP request, for logging or metrics.
  final void Function(LlmAttempt attempt)? onAttempt;

  final http.Client _http;
  final bool _ownsHttp;

  /// Asks for a reply that follows [schema], and returns it decoded by
  /// [decode]. The decoder gets the parsed JSON (a map or a list); errors
  /// it throws, other than [LlmException]s, become [InvalidReply].
  Future<LlmResult<T>> askJson<T>({
    required String system,
    required String prompt,
    required Map<String, Object?> schema,
    required T Function(Object? json) decode,
    int? maxTokens,
    CancelToken? cancel,
  }) async {
    final reply = await generate(
      system: system,
      prompt: prompt,
      schema: schema,
      maxTokens: maxTokens,
      cancel: cancel,
    );
    final Object? json;
    try {
      json = decodeJsonReply(reply.value);
    } on FormatException {
      throw InvalidReply(
        '${provider.name} did not send back JSON.',
        raw: reply.value,
      );
    }
    final T value;
    try {
      value = decode(json);
    } on LlmException {
      rethrow;
    } catch (e) {
      throw InvalidReply(
        '${provider.name} sent back an unexpected shape ($e).',
        raw: reply.value,
      );
    }
    return LlmResult(
      value: value,
      model: reply.model,
      attempts: reply.attempts,
      usage: reply.usage,
    );
  }

  /// Sends one request and returns the reply text. With a [schema] the
  /// text is JSON, but not decoded.
  Future<LlmResult<String>> generate({
    required String system,
    required String prompt,
    Map<String, Object?>? schema,
    int? maxTokens,
    CancelToken? cancel,
  }) async {
    final request = LlmRequest(
      system: system,
      prompt: prompt,
      schema: schema,
      maxTokens: maxTokens,
    );
    var attempts = 0;
    // The most useful reason to report if every model fails.
    LlmException? failure;

    for (final model in provider.models) {
      for (var retryNo = 0; retryNo < retry.maxAttempts; retryNo++) {
        if (retryNo > 0) await _wait(retry.delayBefore(retryNo), cancel);
        attempts++;
        final (code, body, headers) = await _send(
          request,
          model,
          attempts,
          cancel,
        );

        if (code == 200) {
          final reply = _parse(body);
          return LlmResult(
            value: reply.text,
            model: model,
            attempts: attempts,
            usage: reply.usage,
          );
        }
        if (code == 429) {
          failure = RateLimited(
            '${provider.name} limit reached.',
            retryAfter: _retryAfter(headers['retry-after']),
          );
          break; // next model: each has its own quota
        }
        if (code == 404 || (code == 400 && _mentionsRetiredModel(body))) {
          failure ??= ModelUnavailable(
            '${provider.name} has none of these models: '
            '${provider.models.join(', ')}.',
            models: provider.models,
          );
          break;
        }
        if (code == 401 ||
            code == 402 ||
            code == 403 ||
            (code == 400 && _mentionsBadKey(body))) {
          throw InvalidKey(
            '${provider.name} refused the key.',
            statusCode: code,
          );
        }
        if (code < 500) {
          throw RequestFailed(
            'HTTP $code: ${_errorMessage(body) ?? 'request rejected'}',
            statusCode: code,
          );
        }
        if (failure is! RateLimited) {
          failure = ProviderBusy('${provider.name} is busy.', statusCode: code);
        }
      }
    }
    throw failure!;
  }

  /// Closes the HTTP client, unless it was passed in.
  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<(int, String, Map<String, String>)> _send(
    LlmRequest request,
    String model,
    int number,
    CancelToken? cancel,
  ) async {
    if (cancel?.isCancelled ?? false) throw const Cancelled();
    final call = provider.buildCall(request, model: model, apiKey: apiKey);
    final timedOut = Completer<void>();
    final timer = Timer(timeout, timedOut.complete);
    final abort = Future.any([timedOut.future, ?cancel?.whenCancelled]);
    final httpRequest =
        http.AbortableRequest('POST', call.url, abortTrigger: abort)
          ..headers.addAll(call.headers)
          ..body = jsonEncode(call.body);
    final started = DateTime.now();
    int? code;
    Object? error;
    try {
      // Also race the abort here: not every http.Client supports it.
      final response = await Future.any([
        _http.send(httpRequest).then(http.Response.fromStream),
        abort.then<http.Response>((_) => throw const _Aborted()),
      ]);
      code = response.statusCode;
      return (code, utf8.decode(response.bodyBytes), response.headers);
    } catch (e) {
      error = e;
      if (cancel?.isCancelled ?? false) throw const Cancelled();
      if (timedOut.isCompleted) {
        throw LlmTimeout('${provider.name} did not answer in time.');
      }
      if (e is http.ClientException) {
        throw ConnectionFailed('Could not reach ${provider.name}.', cause: e);
      }
      rethrow;
    } finally {
      timer.cancel();
      onAttempt?.call(
        LlmAttempt(
          model: model,
          number: number,
          elapsed: DateTime.now().difference(started),
          statusCode: code,
          error: error,
        ),
      );
    }
  }

  LlmReply _parse(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw InvalidReply(
        '${provider.name} sent an unreadable reply.',
        raw: body,
      );
    }
    try {
      return provider.parseReply(json as Map<String, Object?>);
    } on LlmException {
      rethrow;
    } catch (e) {
      throw InvalidReply(
        '${provider.name} sent an unexpected reply ($e).',
        raw: body,
      );
    }
  }

  Future<void> _wait(Duration delay, CancelToken? cancel) async {
    await Future.any([Future<void>.delayed(delay), ?cancel?.whenCancelled]);
    if (cancel?.isCancelled ?? false) throw const Cancelled();
  }

  static final _badKey = RegExp(
    r'API_KEY_INVALID|api[ _-]?key (is )?(not valid|invalid)|invalid api[ _-]?key',
    caseSensitive: false,
  );

  /// Gemini answers a wrong key with 400, not 401.
  static bool _mentionsBadKey(String body) => _badKey.hasMatch(body);

  static final _model = RegExp('model', caseSensitive: false);
  static final _retired = RegExp(
    'not (found|exist|available|supported)|does not exist|decommission|'
    'deprecat|retired|unknown|invalid',
    caseSensitive: false,
  );

  /// Some services answer a retired model with 400, not 404.
  static bool _mentionsRetiredModel(String body) {
    final message = _errorMessage(body) ?? body;
    return _model.hasMatch(message) && _retired.hasMatch(message);
  }

  /// The `error.message` in an error reply, if it is JSON.
  static String? _errorMessage(String body) {
    try {
      final json = jsonDecode(body);
      final error = json is Map ? json['error'] : null;
      final message = error is Map ? error['message'] : error;
      return message?.toString();
    } on FormatException {
      return null;
    }
  }

  static Duration? _retryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }
}

class _Aborted implements Exception {
  const _Aborted();
}
