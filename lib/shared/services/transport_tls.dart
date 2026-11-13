// 职责: 传输层 TLS 强制校验 —— 拒绝在明文 HTTP 上传输凭据/令牌/内容。
// P0-D B2：远程端点一律强制 https；仅本机回环（loopback）允许 http，
// 以保留本地 OAuth 回调（http://127.0.0.1:<port>/mcp/oauth/callback）、
// 本地 WebDAV/MinIO 等开发场景，同时阻断远程明文降级。
// 关联文件:
//   lib/shared/models/webdav_backup_config.dart
//   lib/shared/models/object_storage_config.dart
//   lib/shared/models/mcp/config.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md

/// [host] 是否为本机回环地址：localhost / 127.0.0.0/8 / ::1 / [::1]。
/// 回环网络不离开本机，无被局域网/公网嗅探的风险，故允许明文 http。
bool isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') {
    return true;
  }
  if (normalized.startsWith('127.')) {
    return true;
  }
  return false;
}

/// [url] 若为「明文 HTTP 且目标非本机回环」，返回 true —— 不得作为
/// 凭据/令牌/内容的传输端点（fail-closed：拒绝远程明文降级）。
///
/// 非 http scheme（含 https）、回环 http、解析失败均返回 false；解析失败
/// 属于调用方既有校验的职责，本函数只负责 TLS 收紧这一增量判断。
bool isCleartextRemoteEndpoint(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return false;
  }
  if (uri.scheme.toLowerCase() != 'http') {
    return false;
  }
  if (uri.host.isEmpty) {
    return false;
  }
  return !isLoopbackHost(uri.host);
}
