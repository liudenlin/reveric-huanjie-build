// 职责: 敏感凭证的 AES-256-GCM 加密基础设施（P0-C 凭证迁移）。
//
// 设计要点:
//   - 密文格式 `enc:v1:<base64(nonce(12) ‖ ciphertext ‖ mac(16))>`，随机 nonce 绝不复用。
//   - 主密钥 32B 随机，独立存放于 OS 安全存储（flutter_secure_storage），与密文分离。
//   - 解密失败（篡改/密钥不符/前缀不符）一律抛 [CredentialDecryptException]，
//     调用方必须 fail-closed（视为凭证无效），不得降级为明文。
//   - 日志只记类型/阶段，不记明文/密文。
//
// 关联文件:
//   lib/shared/services/credentials/credential_migration.dart
//   lib/shared/services/credentials/master_key_store.dart
//   lib/shared/services/ai/codex/credentials.dart（读取侧）

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'master_key_store.dart';

/// 解密失败原因。
enum CredentialDecryptReason {
  /// 存储值不是 `enc:v1:` 前缀（未加密的旧值或非凭证值）。
  not_encrypted,

  /// 主密钥不可用（OS 安全存储不可达 / 密钥缺失）。
  key_unavailable,

  /// 解密失败（密文篡改 / 密钥不符 / 载荷损坏）。
  failed,
}

/// 解密失败异常 —— 上层必须 fail-closed（凭证视为无效）。
class CredentialDecryptException implements Exception {
  const CredentialDecryptException(
    this.reason, {
    this.cause,
    this.stackTrace,
  });

  final CredentialDecryptReason reason;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'CredentialDecryptException(${reason.name})';
}

/// 加密基础设施：AES-256-GCM + 独立主密钥。
///
/// [masterKeyStore] 生产实现为 [SecureStorageMasterKeyStore]
/// （OS 安全存储），测试注入 [InMemoryMasterKeyStore]。
class CredentialCipher {
  CredentialCipher({
    MasterKeyStore? masterKeyStore,
    AesGcm? algorithm,
  })  : _masterKeyStore = masterKeyStore ?? SecureStorageMasterKeyStore(),
        _algorithm = algorithm ?? AesGcm.with256bits();

  final MasterKeyStore _masterKeyStore;
  final AesGcm _algorithm;

  /// P0-D B1：轮换期间的显式密钥覆盖（null = 使用 store 主密钥）。
  ///
  /// 仅在 [withRotatedKey] 作用域内临时置位，用毕恢复，避免轮换
  /// 中途其它加解密读到不一致密钥。
  SecretKey? _rotatedKeyOverride;

  /// 密文前缀 —— 同时用于幂等迁移判定与格式识别。
  static const prefix = 'enc:v1:';

  static const _nonceLength = 12;
  static const _macLength = 16;

  /// 是否已加密（`enc:v1:` 前缀）。未加密的旧值返回 false。
  bool isEncrypted(String stored) => stored.startsWith(prefix);

  /// OS 安全存储可达性探测：不可达时主密钥读写会抛异常，
  /// 调用方据此 fail-closed（凭证不可用，不降级明文）。
  Future<bool> get available async {
    try {
      await _masterKeyStore.read();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 加密明文，返回 `enc:v1:` 密文串。
  ///
  /// [aad] 绑定凭证归属（如 `key:field`），防止跨字段密文互换。
  Future<String> encrypt(String plaintext, {String? aad}) async {
    final key = await _masterKey();
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
      aad: _aadBytes(aad),
    );
    final payload = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return '$prefix${base64Encode(payload.toBytes())}';
  }

  /// 解密 `enc:v1:` 密文，返回明文。
  ///
  /// 前缀不符抛 [CredentialDecryptReason.not_encrypted]；
  /// 主密钥不可用抛 [CredentialDecryptReason.key_unavailable]；
  /// 解密失败（篡改/密钥不符）抛 [CredentialDecryptReason.failed]。
  /// 绝不返回明文降级。
  Future<String> decrypt(String stored, {String? aad}) async {
    if (!isEncrypted(stored)) {
      throw const CredentialDecryptException(
        CredentialDecryptReason.not_encrypted,
      );
    }
    SecretKey key;
    try {
      key = await _masterKey();
    } catch (error, stack) {
      throw CredentialDecryptException(
        CredentialDecryptReason.key_unavailable,
        cause: error,
        stackTrace: stack,
      );
    }
    try {
      final bytes = base64Decode(stored.substring(prefix.length));
      if (bytes.length < _nonceLength + _macLength) {
        throw const FormatException('credential payload too short');
      }
      final nonce = bytes.sublist(0, _nonceLength);
      final mac = bytes.sublist(bytes.length - _macLength);
      final cipherText = bytes.sublist(
        _nonceLength,
        bytes.length - _macLength,
      );
      final plain = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aadBytes(aad),
      );
      return utf8.decode(plain);
    } on CredentialDecryptException {
      rethrow;
    } catch (error, stack) {
      throw CredentialDecryptException(
        CredentialDecryptReason.failed,
        cause: error,
        stackTrace: stack,
      );
    }
  }

  Future<SecretKey> _masterKey() async {
    // P0-D B1：轮换上下文内使用显式密钥（旧/新），其余走 store 主密钥。
    final override = _rotatedKeyOverride;
    if (override != null) {
      return override;
    }
    final existing = await _masterKeyStore.read();
    if (existing != null && existing.isNotEmpty) {
      return SecretKey(base64Decode(existing));
    }
    final key = await _algorithm.newSecretKey();
    await _masterKeyStore.write(base64Encode(await key.extractBytes()));
    return key;
  }

  // ── P0-D B1 主密钥轮换支持 ────────────────────────────────────────

  /// 读取当前主密钥（base64）。无密钥（未初始化）返回 null。
  Future<String?> masterKeyBase64() async {
    final override = _rotatedKeyOverride;
    if (override != null) {
      return base64Encode(await override.extractBytes());
    }
    return _masterKeyStore.read();
  }

  /// 生成新的 32B 主密钥（不持久化；由 [persistMasterKeyBytes] 提交）。
  Future<SecretKey> generateNewSecretKey() => _algorithm.newSecretKey();

  /// 把主密钥（base64）写入 store —— 轮换提交/回滚用。
  Future<void> persistMasterKeyBytes(String base64) =>
      _masterKeyStore.write(base64);

  /// 在 [body] 作用域内用 [key] 作为加解密主密钥（轮换用）。
  ///
  /// 旧密钥解密、新密钥加密分别在各自的 [withRotatedKey] 作用域内进行，
  /// 复用全部现有 helper（encrypt/decrypt/encryptWechatAggregate 等），
  /// 无需 *With 变体。作用域外恢复 store 主密钥。
  Future<T> withRotatedKey<T>(
    SecretKey key,
    Future<T> Function() body,
  ) async {
    final previous = _rotatedKeyOverride;
    _rotatedKeyOverride = key;
    try {
      return await body();
    } finally {
      _rotatedKeyOverride = previous;
    }
  }

  Uint8List _aadBytes(String? aad) =>
      aad == null || aad.isEmpty ? Uint8List(0) : utf8.encode(aad);
}
