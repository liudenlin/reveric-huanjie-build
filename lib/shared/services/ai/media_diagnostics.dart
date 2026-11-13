// 职责: 为音视频 HTTP 诊断移除凭据并限制日志长度，保留 URL 供排查。
// 关联文件:
//   lib/shared/services/ai/audio/client.dart
//   lib/shared/services/ai/video/client.dart

String safeMediaDiagnostic(Object error, String apiKey) {
  var message = error is FormatException ? error.message : error.toString();
  if (apiKey.isNotEmpty) {
    message = message.replaceAll(apiKey, '[redacted]');
  }
  final safe = message
      .replaceAll(
        RegExp(r'Bearer\s+\S+|\bsk-[\w-]+', caseSensitive: false),
        '[redacted]',
      )
      // 凭据常通过查询串传递（?token=/&signature= 等），只脱敏等号后的值，
      // 保留键名、宿主和路径供排查。已是 [redacted] 占位符的值不再包裹，避免二次脱敏。
      .replaceAllMapped(
        RegExp(
          r'((?:[?&])(?:token|access_token|refresh_token|signature|sig|key|apikey|api_key|secret|password|credential|auth)=)(\[redacted\]|[^&\s]*)',
          caseSensitive: false,
        ),
        (m) => '${m.group(1)}[redacted]',
      )
      .replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ');
  return safe.length > 1000 ? '${safe.substring(0, 1000)}…' : safe;
}

/// 脱敏后的供应商错误码和原文，供 Agent 判断失败原因；不用于界面展示。
String? providerErrorDetail(String? code, String? message, String apiKey) {
  final parts = [
    code?.trim(),
    message?.trim(),
  ].whereType<String>().where((part) => part.isNotEmpty);
  return parts.isEmpty ? null : safeMediaDiagnostic(parts.join(': '), apiKey);
}
