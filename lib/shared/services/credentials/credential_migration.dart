// 职责: P0-C 凭证加密迁移编排（惰性 / 幂等 / 可回滚 / fail-closed）。
//
// 把存量明文凭证（app_settings KV 聚合 + ai_providers 表）加密写回为
// `enc:v1:` 密文。迁移模式沿用 P0-B（remote_authorizations_migrated_v5）：
//   - 惰性：首次凭证读写路径调用 [ensureMigrated]，标记置位后短路。
//   - 幂等：每 key 写前 [CredentialCipher.isEncrypted] 检测，已加密跳过。
//   - 可回滚：迁移前把原文备份到 `credentials_migration_backup_v1`（JSON map）。
//   - fail-closed：主密钥不可用 → 不迁移、不设标记、凭证按无效处理。
//
// 关联文件:
//   lib/shared/services/credentials/credential_cipher.dart
//   lib/shared/services/credentials/credential_json.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/daos/ai_provider_dao.dart

import 'dart:convert';

import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/object_storage_config.dart';
import '../../models/network_proxy.dart';
import '../../models/app_settings_aggregate_data.dart';
import 'credential_cipher.dart';
import 'credential_json.dart';

final _log = AppLogger.forModule('CredentialMigration');

/// 凭证加密迁移编排（P0-C）。
///
/// [credentialCipher] 生产默认为 [CredentialCipher]（OS 安全存储主密钥），
/// 测试注入 [InMemoryMasterKeyStore] 兼容实现。
class CredentialMigration {
  CredentialMigration({
    required this.database,
    CredentialCipher? credentialCipher,
  }) : _cipher = credentialCipher ?? CredentialCipher();

  /// 成功迁移后置位（`app_settings` KV）。
  static const migratedFlagKey = 'credentials_encryption_migrated_v1';

  /// 迁移原文备份（`app_settings` KV，JSON map：key → 原文）。
  static const backupKey = 'credentials_migration_backup_v1';

  final AppDatabase database;
  final CredentialCipher _cipher;

  /// 本进程内已尝试/已确保（避免重复探测与重复迁移）。
  bool _ensured = false;

  /// 标记是否已置位（已成功迁移）。
  Future<bool> get isMigrated async {
    final value = await database.appSettingsDao.get(migratedFlagKey);
    return value == '1';
  }

  /// 惰性触发：标记置位或本进程已确保 → 短路返回。
  ///
  /// 主密钥不可用（keyring 不可达）→ 不迁移、不设标记（fail-closed），
  /// 各凭证读写边界已把凭证按无效处理。绝不降级明文。
  ///
  /// 迁移中途失败：保留备份、不设标记，仅记录（不阻断调用方），
  /// 下次进程启动重试；本次运行各读写边界仍以明文兼容 / 幂等写回工作。
  Future<void> ensureMigrated() async {
    if (_ensured) {
      return;
    }
    if (await isMigrated) {
      _ensured = true;
      return;
    }
    if (!await _cipher.available) {
      _log.warning('[P0C] master key unavailable; credential migration aborted');
      _ensured = true; // 本进程不再重复探测；下次启动重试。
      return;
    }
    try {
      await _migrate();
      _ensured = true;
    } catch (error, stackTrace) {
      _log.error(
        '[P0C] ensureMigrated aborted; retry on next process start',
        error: error,
        stackTrace: stackTrace,
      );
      _ensured = true; // 本进程不再反复重试（避免写路径抖动）。
    }
  }

  /// 迁移步骤：备份 → 逐 app_settings key 加密写回 → ai_providers 逐行 →
  /// 成功设标记并删备份。任一步失败：保留备份、不设标记、上抛（下次重试）。
  Future<void> _migrate() async {
    _log.info('[P0C] credential migration START');
    await _backupOriginals();
    try {
      await _migrateAppSettingsKeys();
      await _migrateAiProviders();
      await database.appSettingsDao.set(
        key: migratedFlagKey,
        value: '1',
      );
      await database.appSettingsDao.remove(backupKey);
      _log.info('[P0C] credential migration COMPLETED');
    } catch (error, stackTrace) {
      _log.error(
        '[P0C] credential migration FAILED; backup retained for rollback',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 迁移开始前备份各 key 原文（仅创建一次；已存在则跳过，保留上次失败原文）。
  Future<void> _backupOriginals() async {
    final existing = await database.appSettingsDao.get(backupKey);
    if (existing != null && existing.isNotEmpty) {
      return;
    }
    final snapshot = <String, String>{};
    for (final key in appSettingsKeys) {
      final raw = await database.appSettingsDao.get(key);
      if (raw != null && raw.isNotEmpty) {
        snapshot[key] = raw;
      }
    }
    // ai_providers 原始行（含明文敏感字段），供回滚。
    final rawRows = await database.aiProviderDao.getAllRawForMigration();
    snapshot['ai_providers'] = jsonEncode(
      <Map<String, dynamic>>[
        for (final row in rawRows)
          <String, dynamic>{
            'id': row.id,
            'apiKey': row.apiKey,
            'proxyPassword': row.proxyPassword,
            'secretAccessKey': row.secretAccessKey,
          },
      ],
    );
    if (snapshot.isNotEmpty) {
      await database.appSettingsDao.set(
        key: backupKey,
        value: jsonEncode(snapshot),
      );
    }
  }

  /// 迁移 app_settings 聚合 keys（微信 / MCP / WebDAV / 对象存储 / 代理）。
  Future<void> _migrateAppSettingsKeys() async {
    // 微信：整对象 credentials + chatContexts[].contextToken。
    await _migrateKey(
      RemoteBridgeSettingsData.appSettingsKey,
      (raw) => encryptWechatAggregate(raw, _cipher),
    );
    // MCP：servers[].oauth.{accessToken, refreshToken, registeredClientSecret}。
    await _migrateKey(
      'mcp_servers',
      (raw) => encryptMcpAggregate(raw, _cipher),
    );
    // WebDAV：webDavPassword 字段。
    await _migrateKey(
      StorageSettingsData.appSettingsKey,
      (raw) => encryptJsonField(
        raw,
        'webDavPassword',
        _cipher,
        aad: 'webDavBackupConfig.password',
      ),
    );
    // 对象存储：secretAccessKey 字段。
    await _migrateKey(
      ObjectStorageConfig.appSettingsKey,
      (raw) => encryptJsonField(
        raw,
        'secretAccessKey',
        _cipher,
        aad: 'objectStorage.secretAccessKey',
      ),
    );
    // 代理：password 字段。
    await _migrateKey(
      NetworkProxy.settingsKey,
      (raw) => encryptJsonField(
        raw,
        'password',
        _cipher,
        aad: 'networkProxy.password',
      ),
    );
  }

  /// 单 key 迁移：读 raw → 加密（helper 内部幂等）→ 写回。
  Future<void> _migrateKey(
    String key,
    Future<String> Function(String raw) encrypt,
  ) async {
    final raw = await database.appSettingsDao.get(key);
    if (raw == null || raw.isEmpty) {
      return;
    }
    // 已整体加密（无明文凭证）→ 跳过；聚合 helper 内部亦逐字段幂等。
    if (_cipher.isEncrypted(raw)) {
      return;
    }
    final encrypted = await encrypt(raw);
    await database.appSettingsDao.set(key: key, value: encrypted);
  }

  /// 迁移 ai_providers 表逐行（apiKey / proxyPassword / secretAccessKey）。
  Future<void> _migrateAiProviders() async {
    final rows = await database.aiProviderDao.getAllRawForMigration();
    for (final row in rows) {
      final needsApiKey =
          row.apiKey.isNotEmpty && !_cipher.isEncrypted(row.apiKey);
      final needsProxyPassword = row.proxyPassword.isNotEmpty &&
          !_cipher.isEncrypted(row.proxyPassword);
      final secret = row.secretAccessKey;
      final needsSecret =
          secret != null && secret.isNotEmpty && !_cipher.isEncrypted(secret);
      if (!needsApiKey && !needsProxyPassword && !needsSecret) {
        continue; // 幂等：整行已加密。
      }
      final apiKey = needsApiKey
          ? await _cipher.encrypt(row.apiKey, aad: 'aiProvider.apiKey')
          : row.apiKey;
      final proxyPassword = needsProxyPassword
          ? await _cipher.encrypt(
              row.proxyPassword,
              aad: 'aiProvider.proxyPassword',
            )
          : row.proxyPassword;
      final secretAccessKey = needsSecret
          ? await _cipher.encrypt(
              secret,
              aad: 'aiProvider.secretAccessKey',
            )
          : secret;
      await database.aiProviderDao.updateRawCredentialsForMigration(
        id: row.id,
        apiKey: apiKey,
        proxyPassword: proxyPassword,
        secretAccessKey: secretAccessKey,
        hasSecretAccessKey: secret != null,
      );
    }
  }

  /// 回滚：把备份原文写回 + 清标记 + 删备份（手动/测试恢复用）。
  Future<void> restoreFromBackup() async {
    final backup = await database.appSettingsDao.get(backupKey);
    if (backup == null || backup.isEmpty) {
      return;
    }
    final snapshot = jsonDecode(backup) as Map<String, dynamic>;
    for (final key in appSettingsKeys) {
      final value = snapshot[key];
      if (value is String) {
        await database.appSettingsDao.set(key: key, value: value);
      }
    }
    final aiProvidersRaw = snapshot['ai_providers'];
    if (aiProvidersRaw is String) {
      final rows = (jsonDecode(aiProvidersRaw) as List).cast<Map>();
      for (final row in rows) {
        final id = row['id'] as String;
        await database.aiProviderDao.updateRawCredentialsForMigration(
          id: id,
          apiKey: row['apiKey'] as String? ?? '',
          proxyPassword: row['proxyPassword'] as String? ?? '',
          secretAccessKey: row['secretAccessKey'] as String?,
          hasSecretAccessKey: row.containsKey('secretAccessKey'),
        );
      }
    }
    await database.appSettingsDao.remove(migratedFlagKey);
    await database.appSettingsDao.remove(backupKey);
    _log.info('[P0C] credential migration ROLLED BACK from backup');
  }

  /// 迁移涉及的全部 app_settings keys（P0-D B1 轮换亦复用）。
  static const appSettingsKeys = <String>[
    RemoteBridgeSettingsData.appSettingsKey,
    'mcp_servers',
    StorageSettingsData.appSettingsKey,
    ObjectStorageConfig.appSettingsKey,
    NetworkProxy.settingsKey,
  ];
}
