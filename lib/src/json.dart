import 'dart:convert';

final _fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');

/// Decodes the JSON in a model's reply. Models often wrap it in ```
/// fences or add words around it, so this tries, in order: the whole
/// text, the first fenced block, then the span from the first `{` or `[`
/// to the matching last `}` or `]`. Throws [FormatException] when none
/// is JSON.
Object? decodeJsonReply(String text) {
  final candidates = [
    text.trim(),
    ?_fence.firstMatch(text)?.group(1)?.trim(),
    ?_span(text, '{', '}'),
    ?_span(text, '[', ']'),
  ];
  for (final candidate in candidates) {
    try {
      return jsonDecode(candidate);
    } on FormatException {
      continue;
    }
  }
  throw FormatException('No JSON in reply', text);
}

String? _span(String text, String open, String close) {
  final start = text.indexOf(open);
  final end = text.lastIndexOf(close);
  return start < 0 || end < start ? null : text.substring(start, end + 1);
}
