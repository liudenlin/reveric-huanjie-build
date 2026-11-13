// 职责: 测试凭证加密迁移编排（P0-C）— 惰性触发、幂等、可回滚、fail-closed，
// 覆盖 app_settings 各聚合 key 与 ai_providers 表的加密写回。
// 关联文件:
//   lib/shared/services/credentials/credential_migration.dart
//   lib/shared/services/credentials/credential_cipher.dart
//   lib/shared/services/credentials/credential_json.dart
//   lib/shared/database/app_database.dart

import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';

import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/credentials/credential_cipher.dart';
import 'package:reveric/shared/services/credentials/credential_json.dart';
import 'package:reveric/shared/services/credentials/credential_migration.dart';
import 'package:reveric/shared/services/credentials/master_key_store.dart';

/// 主密钥不可达（keyring 故障）→ fail-closed。
class _UnavailableKeyStore implements MasterKeyStore {
  @override
  Future<String?> read() async => throw Exception('keyring unavailable');
  @override
  Future<void> write(String key) async => throw Exception('keyring unavailable');
}

/// 注入失败：迁移到 networkProxy.password 时 encrypt 抛异常。
class _FailingCipher extends CredentialCipher {
  _FailingCipher({required super.masterKeyStore});
  @override
  Future<String> encrypt(String plaintext, {String? aad}) async {
    if (aad == 'networkProxy.password') {
      throw StateError('injected migration failure');
    }
    return super.encrypt(plaintext, aad: aad);
  }
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// 以明文初始化全部凭证（app_settings 聚合 + ai_providers 一行）。
  Future<void> seedPlainCredentials() async {
    await db.appSettingsDao.set(
      key: 'remote_bridge_settings',
      value:
          '{"wechat":{"credentials":{"token":"wx-token"},'
          '"chatContexts":[{"chatId":"c1","contextToken":"ctx-1"}]}}',
    );
    await db.appSettingsDao.set(
      key: 'mcp_servers',
      value:
          '{"servers":[{"name":"s1","url":"http://mcp",'
          '"oauth":{"accessToken":"at-1","refreshToken":"rt-1",'
          '"registeredClientSecret":"cs-1"}}]}',
    );
    await db.appSettingsDao.set(
      key: 'storage_settings',
      value: '{"webDavPassword":"webdav-pw","webDavServerUrl":"http://dav"}',
    );
    await db.appSettingsDao.set(
      key: 'object_storage_settings',
      value: '{"provider":"s3","accessKeyId":"ak-1","secretAccessKey":"sk-1"}',
    );
    await db.appSettingsDao.set(
      key: 'network_proxy',
      value:
          '{"mode":"custom","url":"http://127.0.0.1:8080",'
          '"username":"proxy-u","password":"proxy-pw"}',
    );
    // ai_providers 明文行（deleted_at=0 为 notDeletedSentinel）。
    await db.customStatement(
      "INSERT INTO ai_providers "
      "(id, name, type, api_key, proxy_password, secret_access_key, "
      "deleted_at, updated_at) "
      "VALUES ('p1','n1','openai','api-key-1','proxy-pw-1','sk-1',0,0)",
    );
  }

  CredentialMigration migration(CredentialCipher cipher) =>
      CredentialMigration(database: db, credentialCipher: cipher);

  test('迁移成功：各 key 加密 + ai_providers 加密 + 标记置位 + 备份删除',
      () async {
    await seedPlainCredentials();
    await migration(
      CredentialCipher(masterKeyStore: InMemoryMasterKeyStore()),
    ).ensureMigrated();

    // app_settings 聚合 key 均为 enc:v1: 且不含明文。
    final wechat = await db.appSettingsDao.get('remote_bridge_settings');
    expect(wechat, isNot(contains('wx-token')));
    expect(wechat, isNot(contains('ctx-1')));
    expect(wechat, contains(CredentialCipher.prefix));

    final mcp = await db.appSettingsDao.get('mcp_servers');
    expect(mcp, isNot(contains('at-1')));
    expect(mcp, contains(CredentialCipher.prefix));

    final webdav = await db.appSettingsDao.get('storage_settings');
    expect(webdav, isNot(contains('webdav-pw')));
    expect(webdav, contains(CredentialCipher.prefix));

    final obj = await db.appSettingsDao.get('object_storage_settings');
    expect(obj, isNot(contains('sk-1')));
    expect(obj, contains(CredentialCipher.prefix));

    final proxy = await db.appSettingsDao.get('network_proxy');
    expect(proxy, isNot(contains('proxy-pw')));
    expect(proxy, contains(CredentialCipher.prefix));

    // ai_providers 行。
    final row = (await db.aiProviderDao.getAllRawForMigration()).single;
    expect(row.apiKey, startsWith(CredentialCipher.prefix));
    expect(row.apiKey, isNot(contains('api-key-1')));
    expect(row.proxyPassword, startsWith(CredentialCipher.prefix));
    expect(row.secretAccessKey, startsWith(CredentialCipher.prefix));

    // 标记置位、备份删除。
    expect(
      await db.appSettingsDao.get(CredentialMigration.migratedFlagKey),
      '1',
    );
    expect(await db.appSettingsDao.get(CredentialMigration.backupKey), isNull);
  });

  test('迁移后读路径可解密还原明文（各接入点序列化兼容）', () async {
    await seedPlainCredentials();
    final cipher = CredentialCipher(masterKeyStore: InMemoryMasterKeyStore());
    await migration(cipher).ensureMigrated();

    // WebDAV：decryptJsonFieldFailClosed 还原 webDavPassword。
    final webdav = await db.appSettingsDao.get('storage_settings');
    final webdavDecrypted = await decryptJsonFieldFailClosed(
      webdav!,
      'webDavPassword',
      cipher,
      aad: 'webDavBackupConfig.password',
    );
    expect(webdavDecrypted, contains('webdav-pw'));

    // 代理：password 还原。
    final proxy = await db.appSettingsDao.get('network_proxy');
    final proxyDecrypted = await decryptJsonFieldFailClosed(
      proxy!,
      'password',
      cipher,
      aad: 'networkProxy.password',
    );
    expect(proxyDecrypted, contains('proxy-pw'));

    // ai_providers：raw 行解密还原 apiKey。
    final row = (await db.aiProviderDao.getAllRawForMigration()).single;
    expect(
      await cipher.decrypt(row.apiKey, aad: 'aiProvider.apiKey'),
      'api-key-1',
    );
    expect(
      await cipher.decrypt(row.secretAccessKey!, aad: 'aiProvider.secretAccessKey'),
      'sk-1',
    );
  });

  test('迁移幂等：重复 ensureMigrated 不重复加密、不重建备份', () async {
    await seedPlainCredentials();
    final m = migration(
      CredentialCipher(masterKeyStore: InMemoryMasterKeyStore()),
    );
    await m.ensureMigrated();
    final webdavAfterFirst = await db.appSettingsDao.get('storage_settings');

    await m.ensureMigrated(); // 标记已置位 → 短路。
    final webdavAfterSecond = await db.appSettingsDao.get('storage_settings');
    expect(webdavAfterSecond, webdavAfterFirst); // 不再变化。
    expect(
      await db.appSettingsDao.get(CredentialMigration.backupKey),
      isNull, // 不重建备份。
    );
  });

  test('惰性触发：标记置位后短路，数据保持密文', () async {
    await seedPlainCredentials();
    final m = migration(
      CredentialCipher(masterKeyStore: InMemoryMasterKeyStore()),
    );
    await m.ensureMigrated();
    // 进程内再次 ensureMigrated 直接短路（_ensured）。
    await m.ensureMigrated();
    final proxy = await db.appSettingsDao.get('network_proxy');
    expect(proxy, contains(CredentialCipher.prefix));
  });

  test('主密钥不可用 → fail-closed：不迁移、不设标记、不建备份', () async {
    await seedPlainCredentials();
    final m = migration(
      CredentialCipher(masterKeyStore: _UnavailableKeyStore()),
    );
    await m.ensureMigrated();

    expect(
      await db.appSettingsDao.get(CredentialMigration.migratedFlagKey),
      isNull,
    );
    expect(await db.appSettingsDao.get(CredentialMigration.backupKey), isNull);
    // 数据保持明文（未迁移）。
    final proxy = await db.appSettingsDao.get('network_proxy');
    expect(proxy, contains('proxy-pw'));
  });

  test('迁移失败：保留备份、不设标记；restoreFromBackup 回滚还原', () async {
    await seedPlainCredentials();
    final m = migration(_FailingCipher(masterKeyStore: InMemoryMasterKeyStore()));
    await m.ensureMigrated(); // 内部捕获，不 rethrow。

    // 失败：备份保留、标记未置。
    expect(await db.appSettingsDao.get(CredentialMigration.backupKey), isNotNull);
    expect(
      await db.appSettingsDao.get(CredentialMigration.migratedFlagKey),
      isNull,
    );
    // 失败点是 networkProxy.password（代理仍明文），前面的 WebDAV 已加密。
    final webdav = await db.appSettingsDao.get('storage_settings');
    expect(webdav, contains(CredentialCipher.prefix));
    final proxy = await db.appSettingsDao.get('network_proxy');
    expect(proxy, contains('proxy-pw'));

    // 回滚：全部还原明文 + 清标记 + 删备份。
    await m.restoreFromBackup();
    expect(
      await db.appSettingsDao.get('storage_settings'),
      contains('webdav-pw'),
    );
    expect(
      await db.appSettingsDao.get('network_proxy'),
      contains('proxy-pw'),
    );
    expect(
      await db.appSettingsDao.get('remote_bridge_settings'),
      contains('wx-token'),
    );
    expect(
      await db.appSettingsDao.get(CredentialMigration.migratedFlagKey),
      isNull,
    );
    expect(await db.appSettingsDao.get(CredentialMigration.backupKey), isNull);
  });

  test('旧明文兼容：迁移前 isEncrypted=false，读路径直通', () async {
    await seedPlainCredentials();
    final cipher = CredentialCipher(masterKeyStore: InMemoryMasterKeyStore());
    // 迁移前，明文值 isEncrypted=false。
    final proxy = await db.appSettingsDao.get('network_proxy');
    final proxyValue =
        (proxy!.split('"password":"').last.split('"').first);
    expect(cipher.isEncrypted(proxyValue), isFalse);
  });
}
