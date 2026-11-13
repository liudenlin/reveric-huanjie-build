// 职责: 主密钥存储抽象与实现（P0-C 凭证迁移）。
//
// 生产实现 [SecureStorageMasterKeyStore] 用 flutter_secure_storage
// （Windows DPAPI / macOS-iOS Keychain / Linux libsecret / Android Keystore），
// 保证主密钥与密文（SQLite）分离、受 OS 账户级保护。
// 测试注入 [InMemoryMasterKeyStore]，避免依赖平台插件。
//
// 关联文件:
//   lib/shared/services/credentials/credential_cipher.dart

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 主密钥存取抽象（单个值）。
abstract interface class MasterKeyStore {
  Future<String?> read();
  Future<void> write(String key);
}

/// 主密钥存放于 OS 安全存储。
class SecureStorageMasterKeyStore implements MasterKeyStore {
  SecureStorageMasterKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const keyName = 'reveric.credential.master.v1';

  @override
  Future<String?> read() => _storage.read(key: keyName);

  @override
  Future<void> write(String key) => _storage.write(key: keyName, value: key);
}

/// 内存主密钥存储（测试用）。
class InMemoryMasterKeyStore implements MasterKeyStore {
  InMemoryMasterKeyStore([this._value]);

  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String key) async => _value = key;
}
