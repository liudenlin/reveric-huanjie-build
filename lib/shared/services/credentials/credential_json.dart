// 职责: 凭证 JSON 字段的加解密后处理（P0-C 凭证迁移）。
//
// 各凭证聚合 JSON（app_settings value / 模型 encode）在持久化边界做
// "敏感字段加密、读取时解密"，models 层保持纯数据与同步序列化不变。
// 加密边界在异步 provider/service 层，符合 models 不依赖 services 的分层。
//
// 关联文件:
//   lib/shared/services/credentials/credential_cipher.dart
//   lib/shared/providers/remote_bridge_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/object_storage/service.dart
//   lib/shared/services/ai/codex/credentials.dart

import 'dart:convert';

import 'credential_cipher.dart';

/// 对 JSON 对象中**单个字符串字段**加密（写入侧）。
///
/// 空值 / 已加密（幂等）原样返回；[aad] 缺省用 [field]。
Future<String> encryptJsonField(
  String json,
  String field,
  CredentialCipher cipher, {
  String? aad,
}) async {
  final map = jsonDecode(json) as Map<String, dynamic>;
  final value = map[field];
  if (value is String && value.isNotEmpty && !cipher.isEncrypted(value)) {
    map[field] = await cipher.encrypt(value, aad: aad ?? field);
  }
  return jsonEncode(map);
}

/// 对 JSON 对象中**单个字符串字段**解密（读取侧）。
///
/// 未加密（旧明文 / 空值）原样返回；解密失败抛 [CredentialDecryptException]。
Future<String> decryptJsonField(
  String json,
  String field,
  CredentialCipher cipher, {
  String? aad,
}) async {
  final map = jsonDecode(json) as Map<String, dynamic>;
  final value = map[field];
  if (value is String && cipher.isEncrypted(value)) {
    map[field] = await cipher.decrypt(value, aad: aad ?? field);
  }
  return jsonEncode(map);
}

/// 单字段解密，失败时该字段**置空**（fail-closed，不返回明文）。
///
/// 密钥不可达 / 密文损坏 / AAD 不匹配时，宁置空该凭证（用户重新输入），
/// 也绝不把密文当作明文返回。写侧见 [encryptJsonField]。
Future<String> decryptJsonFieldFailClosed(
  String json,
  String field,
  CredentialCipher cipher, {
  String? aad,
}) async {
  try {
    return await decryptJsonField(json, field, cipher, aad: aad);
  } catch (_) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    map[field] = '';
    return jsonEncode(map);
  }
}

/// 微信聚合（`RemoteBridgeSettingsData` JSON）敏感字段加密（写入侧）。
///
/// - `wechat.credentials`（Map）整对象加密为字符串。
/// - `wechat.chatContexts[].contextToken`（String）字段级加密。
/// 已加密 / 空值原样返回（幂等）。
Future<String> encryptWechatAggregate(
  String json,
  CredentialCipher cipher,
) async {
  final map = jsonDecode(json) as Map<String, dynamic>;
  final wechat = map['wechat'];
  if (wechat is! Map) {
    return json;
  }
  final credentials = wechat['credentials'];
  if (credentials is Map && credentials.isNotEmpty) {
    wechat['credentials'] = await cipher.encrypt(
      jsonEncode(credentials),
      aad: 'wechat.credentials',
    );
  }
  final contexts = wechat['chatContexts'];
  if (contexts is List) {
    for (final entry in contexts) {
      if (entry is Map && entry['contextToken'] is String) {
        final token = entry['contextToken'] as String;
        if (token.isNotEmpty && !cipher.isEncrypted(token)) {
          entry['contextToken'] = await cipher.encrypt(
            token,
            aad: 'wechat.contextToken',
          );
        }
      }
    }
  }
  return jsonEncode(map);
}

/// 微信聚合敏感字段解密（读取侧）。
Future<String> decryptWechatAggregate(
  String json,
  CredentialCipher cipher,
) async {
  final map = jsonDecode(json) as Map<String, dynamic>;
  final wechat = map['wechat'];
  if (wechat is! Map) {
    return json;
  }
  final credentials = wechat['credentials'];
  if (credentials is String && cipher.isEncrypted(credentials)) {
    final decrypted = await cipher.decrypt(
      credentials,
      aad: 'wechat.credentials',
    );
    wechat['credentials'] = jsonDecode(decrypted);
  }
  final contexts = wechat['chatContexts'];
  if (contexts is List) {
    for (final entry in contexts) {
      if (entry is Map && entry['contextToken'] is String) {
        final token = entry['contextToken'] as String;
        if (cipher.isEncrypted(token)) {
          entry['contextToken'] = await cipher.decrypt(
            token,
            aad: 'wechat.contextToken',
          );
        }
      }
    }
  }
  return jsonEncode(map);
}

/// MCP 聚合（`McpSettings` JSON）OAuth token 字段加密（写入/迁移侧）。
///
/// 结构：`servers[].oauth.{accessToken, refreshToken, registeredClientSecret}`。
/// 与 [McpOAuthCoordinator._persist] 的字段一致；已加密 / 空值原样返回（幂等）。
Future<String> encryptMcpAggregate(
  String json,
  CredentialCipher cipher,
) async {
  final map = jsonDecode(json) as Map<String, dynamic>;
  final servers = map['servers'];
  if (servers is! List) {
    return json;
  }
  const fields = <String>[
    'accessToken',
    'refreshToken',
    'registeredClientSecret',
  ];
  for (final entry in servers) {
    if (entry is! Map) {
      continue;
    }
    final oauth = entry['oauth'];
    if (oauth is! Map) {
      continue;
    }
    for (final field in fields) {
      final value = oauth[field];
      if (value is String && value.isNotEmpty && !cipher.isEncrypted(value)) {
        oauth[field] = await cipher.encrypt(value, aad: 'mcp.$field');
      }
    }
  }
  return jsonEncode(map);
}

/// MCP 聚合 OAuth token 字段解密（读取/轮换侧）。
///
/// 与 [encryptMcpAggregate] 互逆：`servers[].oauth` 内已加密的 3 个字段
/// 解密为明文；未加密 / 空值原样返回（幂等）。解密失败抛
/// [CredentialDecryptException]（fail-closed）。
Future<String> decryptMcpAggregate(
  String json,
  CredentialCipher cipher,
) async {
  final map = jsonDecode(json) as Map<String, dynamic>;
  final servers = map['servers'];
  if (servers is! List) {
    return json;
  }
  const fields = <String>[
    'accessToken',
    'refreshToken',
    'registeredClientSecret',
  ];
  for (final entry in servers) {
    if (entry is! Map) {
      continue;
    }
    final oauth = entry['oauth'];
    if (oauth is! Map) {
      continue;
    }
    for (final field in fields) {
      final value = oauth[field];
      if (value is String && cipher.isEncrypted(value)) {
        oauth[field] = await cipher.decrypt(value, aad: 'mcp.$field');
      }
    }
  }
  return jsonEncode(map);
}
