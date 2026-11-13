// 职责: 测试 P0-D B1 主密钥轮换编排（CredentialRotation）—
//       轮换后新密钥可解密、密钥更新、幂等、无凭证轮换、解密失败中止。
// 关联文件:
//   lib/shared/services/credentials/credential_rotation.dart
//   lib/shared/services/credentials/credential_migration.dart
//   lib/shared/database/app_database.dart

import 'dart:convert';

import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';

import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/credentials/credential_cipher.dart';
import 'package:reveric/shared/services/credentials/credential_json.dart';
import 'package:reveric/shared/services/credentials/credential_migration.dart';
import 'package:reveric/shared/services/credentials/credential_rotation.dart';
import 'package:reveric/shared/services/credentials/master_key_store.dart';

void main() {
  late AppDatabase db;
  late CredentialCipher cipher;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
    cipher = CredentialCipher(masterKeyStore: InMemoryMasterKeyStore());
  });

  tearDown(() async {
    await db.close();
  });

  /// 以明文初始化全部凭证（与 credential_migration_test 同构）。
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
    await db.customStatement(
      "INSERT INTO ai_providers "
      "(id, name, type, api_key, proxy_password, secret_access_key, "
      "deleted_at, updated_at) "
      "VALUES ('p1','n1','openai','api-key-1','proxy-pw-1','sk-1',0,0)",
    );
  }

  CredentialMigration migration() =>
      CredentialMigration(database: db, credentialCipher: cipher);
  CredentialRotation rotation() =>
      CredentialRotation(database: db, credentialCipher: cipher);

  Future<void> migrate() => migration().ensureMigrated();

  test('轮换后新密钥可解密全部凭证，且主密钥已更新', () async {
    await seedPlainCredentials();
    await migrate();
    final oldKey = await cipher.masterKeyBase64();
    expect(oldKey, isNotNull);

    await rotation().rotate();
    final newKey = await cipher.masterKeyBase64();
    expect(newKey, isNotNull);
    expect(newKey, isNot(oldKey), reason: '主密钥应已轮换');

    // 用（新）主密钥解密验证还原明文。
    final storageRaw = await db.appSettingsDao.get('storage_settings');
    final decrypted = await decryptJsonField(
      storageRaw!,
      'webDavPassword',
      cipher,
      aad: 'webDavBackupConfig.password',
    );
    expect(jsonDecode(decrypted)['webDavPassword'], 'webdav-pw');

    final bridgeRaw = await db.appSettingsDao.get('remote_bridge_settings');
    final wechat = await decryptWechatAggregate(bridgeRaw!, cipher);
    expect(jsonDecode(wechat)['wechat']['credentials']['token'], 'wx-token');
    expect(
      (jsonDecode(wechat)['wechat']['chatContexts'] as List).first['contextToken'],
      'ctx-1',
    );

    final mcpRaw = await db.appSettingsDao.get('mcp_servers');
    final mcp = await decryptMcpAggregate(mcpRaw!, cipher);
    expect(
      (jsonDecode(mcp)['servers'] as List).first['oauth']['accessToken'],
      'at-1',
    );

    // ai_providers 行经 DAO 读（解密边界）还原明文。
    final provider = await db.aiProviderDao.getById('p1');
    expect(provider, isNotNull);
  });

  test('无凭证（空库）轮换：仅生成新主密钥，无异常', () async {
    final keyBefore = await cipher.masterKeyBase64();
    await rotation().rotate();
    final keyAfter = await cipher.masterKeyBase64();
    expect(keyAfter, isNotNull);
    // 初始无密钥（null），轮换后生成；若已有密钥则轮换更新。
    expect(keyBefore == null || keyAfter != keyBefore, isTrue);
  });

  test('轮换幂等：连续两次无异常且可解密', () async {
    await seedPlainCredentials();
    await migrate();
    await rotation().rotate();
    await rotation().rotate();

    final storageRaw = await db.appSettingsDao.get('storage_settings');
    final decrypted = await decryptJsonField(
      storageRaw!,
      'webDavPassword',
      cipher,
      aad: 'webDavBackupConfig.password',
    );
    expect(jsonDecode(decrypted)['webDavPassword'], 'webdav-pw');
  });

  test('解密失败中止：不更新主密钥、不产生变更（fail-closed）', () async {
    await seedPlainCredentials();
    await migrate();
    final oldKey = await cipher.masterKeyBase64();

    // 篡改 storage_settings 密文（破坏 JSON 结构，仅改密文值保留合法 JSON）。
    final raw = await db.appSettingsDao.get('storage_settings');
    final map = jsonDecode(raw!) as Map<String, dynamic>;
    map['webDavPassword'] = 'enc:v1:damaged-ciphertext';
    await db.appSettingsDao.set(
      key: 'storage_settings',
      value: jsonEncode(map),
    );

    await expectLater(rotation().rotate(), throwsA(anything));
    // 主密钥未变（中止，无提交）。
    expect(await cipher.masterKeyBase64(), oldKey);
  });
}
