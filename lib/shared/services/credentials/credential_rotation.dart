// 职责: P0-D B1 主密钥轮换编排 —— 用新主密钥全量重加密所有已加密凭证。
//
// 安全模型（与 P0-C 迁移同源的 fail-closed / 可回滚）:
//   - 收集阶段（内存）：读全部已加密字段 → 旧密钥解密 → 新密钥加密。
//     任一解密/加密失败 → 中止，**无任何持久化变更**（保留旧密钥与旧密文）。
//   - 提交阶段：写新主密钥 → 写回全部新密文。写回中途失败 → 尽力回滚
//     （写回旧主密钥 + 恢复已写字段为旧密文），仍失败则如实上报（不 fail-open）。
//   - 幂等：重复 rotate() 幂等（新密钥重新生成、全量重加密）。
//   - 主密钥缺失（无旧密钥）→ 仅生成并持久化新密钥（无凭证可轮换）。
//
// 关联文件:
//   lib/shared/services/credentials/credential_cipher.dart
//   lib/shared/services/credentials/credential_json.dart
//   lib/shared/services/credentials/credential_migration.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/daos/ai_provider_dao.dart

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/object_storage_config.dart';
import '../../models/network_proxy.dart';
import '../../models/app_settings_aggregate_data.dart';
import 'credential_cipher.dart';
import 'credential_json.dart';
import 'credential_migration.dart';

final _log = AppLogger.forModule('CredentialRotation');

/// P0-D B1：主密钥轮换（全量重加密）。
///
/// [credentialCipher] 生产默认为 [CredentialCipher]（OS 安全存储主密钥），
/// 测试注入 [InMemoryMasterKeyStore] 兼容实现。
class CredentialRotation {
  CredentialRotation({
    required this.database,
    CredentialCipher? credentialCipher,
  }) : _cipher = credentialCipher ?? CredentialCipher();

  final AppDatabase database;
  final CredentialCipher _cipher;

  /// 执行一次主密钥轮换。成功返回 true；失败抛异常（已尽力回滚）。
  Future<bool> rotate() async {
    // 1. 旧密钥（回滚基线）；无旧密钥 → 仅生成并持久化新密钥。
    final oldKeyB64 = await _cipher.masterKeyBase64();
    final newKey = await _cipher.generateNewSecretKey();
    final newKeyB64 = base64Encode(await newKey.extractBytes());

    // 2. 收集阶段（内存）—— 任一失败即中止（无持久化变更）。
    final appSettings = <String, _KeySnapshot>{};
    for (final key in CredentialMigration.appSettingsKeys) {
      final raw = await database.appSettingsDao.get(key);
      if (raw == null || raw.isEmpty) {
        continue;
      }
      final re = await _reencryptAppSettingsKey(
        key,
        raw,
        oldKeyB64,
        newKey,
      );
      if (re != null) {
        appSettings[key] = _KeySnapshot(oldRaw: raw, newRaw: re);
      }
    }
    final providerRows = await database.aiProviderDao.getAllRawForMigration();
    final providers = <_ProviderSnapshot>[];
    for (final row in providerRows) {
      providers.add(await _reencryptProviderRow(row, oldKeyB64, newKey));
    }

    // 3. 提交阶段：写新主密钥 → 写回全部新密文。
    _log.info(
      '[P0D] master key rotation START '
      '(keys=${appSettings.length}, providers=${providers.length})',
    );
    await _cipher.persistMasterKeyBytes(newKeyB64);
    try {
      for (final entry in appSettings.entries) {
        await database.appSettingsDao.set(
          key: entry.key,
          value: entry.value.newRaw,
        );
      }
      for (final p in providers) {
        await database.aiProviderDao.updateRawCredentialsForMigration(
          id: p.id,
          apiKey: p.newApiKey,
          proxyPassword: p.newProxyPassword,
          secretAccessKey: p.newSecretAccessKey,
          hasSecretAccessKey: p.hasSecretAccessKey,
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        '[P0D] master key rotation COMMIT failed; rolling back',
        error: error,
        stackTrace: stackTrace,
      );
      await _rollbackCommit(oldKeyB64, appSettings, providers);
      rethrow;
    }
    _log.info('[P0D] master key rotation COMPLETED');
    return true;
  }

  /// 回滚：写回旧主密钥 + 恢复已写字段为旧密文（尽力而为）。
  Future<void> _rollbackCommit(
    String? oldKeyB64,
    Map<String, _KeySnapshot> appSettings,
    List<_ProviderSnapshot> providers,
  ) async {
    if (oldKeyB64 != null) {
      try {
        await _cipher.persistMasterKeyBytes(oldKeyB64);
      } catch (error, stackTrace) {
        _log.error(
          '[P0D] rotation rollback: restore old master key FAILED',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    for (final entry in appSettings.entries) {
      try {
        await database.appSettingsDao.set(
          key: entry.key,
          value: entry.value.oldRaw,
        );
      } catch (error, stackTrace) {
        _log.error(
          '[P0D] rotation rollback: restore ${entry.key} FAILED',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    for (final p in providers) {
      try {
        await database.aiProviderDao.updateRawCredentialsForMigration(
          id: p.id,
          apiKey: p.oldApiKey,
          proxyPassword: p.oldProxyPassword,
          secretAccessKey: p.oldSecretAccessKey,
          hasSecretAccessKey: p.hasSecretAccessKey,
        );
      } catch (error, stackTrace) {
        _log.error(
          '[P0D] rotation rollback: restore provider ${p.id} FAILED',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// 按 key 类型重加密单个 app_settings 聚合（旧密钥解密 → 新密钥加密）。
  Future<String?> _reencryptAppSettingsKey(
    String key,
    String raw,
    String? oldKeyB64,
    SecretKey newKey,
  ) async {
    final oldKey = oldKeyB64 == null
        ? null
        : SecretKey(base64Decode(oldKeyB64));
    if (oldKey == null) {
      // 无旧密钥：无法解密已有密文（理论上不应存在），跳过该 key。
      _log.warning('[P0D] rotation: no old master key; skip $key');
      return null;
    }
    switch (key) {
      case RemoteBridgeSettingsData.appSettingsKey:
        final plain = await _cipher.withRotatedKey(
          oldKey,
          () => decryptWechatAggregate(raw, _cipher),
        );
        return _cipher.withRotatedKey(
          newKey,
          () => encryptWechatAggregate(plain, _cipher),
        );
      case 'mcp_servers':
        final plain = await _cipher.withRotatedKey(
          oldKey,
          () => decryptMcpAggregate(raw, _cipher),
        );
        return _cipher.withRotatedKey(
          newKey,
          () => encryptMcpAggregate(plain, _cipher),
        );
      case StorageSettingsData.appSettingsKey:
        final plain = await _cipher.withRotatedKey(
          oldKey,
          () => decryptJsonField(
            raw,
            'webDavPassword',
            _cipher,
            aad: 'webDavBackupConfig.password',
          ),
        );
        return _cipher.withRotatedKey(
          newKey,
          () => encryptJsonField(
            plain,
            'webDavPassword',
            _cipher,
            aad: 'webDavBackupConfig.password',
          ),
        );
      case ObjectStorageConfig.appSettingsKey:
        final plain = await _cipher.withRotatedKey(
          oldKey,
          () => decryptJsonField(
            raw,
            'secretAccessKey',
            _cipher,
            aad: 'objectStorage.secretAccessKey',
          ),
        );
        return _cipher.withRotatedKey(
          newKey,
          () => encryptJsonField(
            plain,
            'secretAccessKey',
            _cipher,
            aad: 'objectStorage.secretAccessKey',
          ),
        );
      case NetworkProxy.settingsKey:
        final plain = await _cipher.withRotatedKey(
          oldKey,
          () => decryptJsonField(
            raw,
            'password',
            _cipher,
            aad: 'networkProxy.password',
          ),
        );
        return _cipher.withRotatedKey(
          newKey,
          () => encryptJsonField(
            plain,
            'password',
            _cipher,
            aad: 'networkProxy.password',
          ),
        );
      default:
        // 非凭证 key（不应出现在 appSettingsKeys）；保持原样。
        return raw;
    }
  }

  /// 重加密单个 ai_providers 行（apiKey / proxyPassword / secretAccessKey）。
  Future<_ProviderSnapshot> _reencryptProviderRow(
    AiProvider row,
    String? oldKeyB64,
    SecretKey newKey,
  ) async {
    final oldKey = oldKeyB64 == null
        ? null
        : SecretKey(base64Decode(oldKeyB64));
    final hasSecret = row.secretAccessKey != null;

    Future<String?> reencrypt(String? stored, String aad) async {
      if (stored == null || stored.isEmpty) {
        return stored;
      }
      if (oldKey == null) {
        return stored;
      }
      final plain = await _cipher.withRotatedKey(
        oldKey,
        () => _cipher.decrypt(stored, aad: aad),
      );
      return _cipher.withRotatedKey(
        newKey,
        () => _cipher.encrypt(plain, aad: aad),
      );
    }

    return _ProviderSnapshot(
      id: row.id,
      oldApiKey: row.apiKey,
      newApiKey: (await reencrypt(row.apiKey, 'aiProvider.apiKey')) ?? '',
      oldProxyPassword: row.proxyPassword,
      newProxyPassword:
          (await reencrypt(row.proxyPassword, 'aiProvider.proxyPassword')) ??
          '',
      oldSecretAccessKey: row.secretAccessKey,
      newSecretAccessKey: await reencrypt(
        row.secretAccessKey,
        'aiProvider.secretAccessKey',
      ),
      hasSecretAccessKey: hasSecret,
    );
  }
}

/// 单 app_settings key 的轮换快照（旧/新密文，回滚用）。
class _KeySnapshot {
  _KeySnapshot({required this.oldRaw, required this.newRaw});
  final String oldRaw;
  final String newRaw;
}

/// 单 ai_providers 行的轮换快照（旧/新列，回滚用）。
class _ProviderSnapshot {
  _ProviderSnapshot({
    required this.id,
    required this.oldApiKey,
    required this.newApiKey,
    required this.oldProxyPassword,
    required this.newProxyPassword,
    required this.oldSecretAccessKey,
    required this.newSecretAccessKey,
    required this.hasSecretAccessKey,
  });
  final String id;
  final String oldApiKey;
  final String newApiKey;
  final String oldProxyPassword;
  final String newProxyPassword;
  final String? oldSecretAccessKey;
  final String? newSecretAccessKey;
  final bool hasSecretAccessKey;
}
