// 职责: 凭证加密单例（P0-C 凭证迁移）。
//
// 供各接入点（AI Provider DAO / 对象存储 / WebDAV / 代理等）在读写边界
// 使用同一 CredentialCipher 实例。测试经 [debugSetCredentialCipher] 覆盖为
// 内存主密钥实现（InMemoryMasterKeyStore），避免依赖平台插件。
//
// 关联文件:
//   lib/shared/services/credentials/credential_cipher.dart
//   lib/shared/database/daos/ai_provider_dao.dart

import 'package:meta/meta.dart';

import 'credential_cipher.dart';

CredentialCipher? _override;

/// 生产默认 [CredentialCipher]（主密钥 OS 安全存储）；测试可覆盖。
CredentialCipher get credentialCipher => _override ??= CredentialCipher();

@visibleForTesting
void debugSetCredentialCipher(CredentialCipher? cipher) {
  _override = cipher;
}
