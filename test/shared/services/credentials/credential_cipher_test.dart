// 职责: 测试凭证加密基础设施（P0-C）— AES-GCM 加解密往返、篡改检测、
// 密钥缺失 fail-closed、旧值兼容、聚合/字段级 JSON 加解密与幂等。
// 关联文件:
//   lib/shared/services/credentials/credential_cipher.dart
//   lib/shared/services/credentials/credential_json.dart
//   lib/shared/services/credentials/credential_cipher_singleton.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:reveric/shared/services/credentials/credential_cipher.dart';
import 'package:reveric/shared/services/credentials/credential_cipher_singleton.dart';
import 'package:reveric/shared/services/credentials/credential_json.dart';
import 'package:reveric/shared/services/credentials/master_key_store.dart';

/// 模拟主密钥不可达（OS keyring 故障）→ fail-closed。
class _UnavailableKeyStore implements MasterKeyStore {
  @override
  Future<String?> read() async => throw Exception('keyring unavailable');

  @override
  Future<void> write(String key) async => throw Exception('keyring unavailable');
}

/// 可注入初始主密钥的 store（复现既有主密钥场景）。
class _SeededKeyStore implements MasterKeyStore {
  _SeededKeyStore(this._value);
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String key) async => _value = key;
}

void main() {
  group('CredentialCipher 加解密', () {
    late CredentialCipher cipher;
    late InMemoryMasterKeyStore store;

    setUp(() {
      store = InMemoryMasterKeyStore();
      cipher = CredentialCipher(masterKeyStore: store);
    });

    test('加解密往返（AES-256-GCM，随机 nonce 不复用）', () async {
      const plaintext = 'sk-ant-abcdef1234567890';
      final encrypted = await cipher.encrypt(plaintext, aad: 'aiProvider.apiKey');
      expect(cipher.isEncrypted(encrypted), isTrue);
      expect(encrypted, startsWith(CredentialCipher.prefix));
      expect(encrypted, isNot(contains(plaintext)));

      final decrypted = await cipher.decrypt(encrypted, aad: 'aiProvider.apiKey');
      expect(decrypted, plaintext);
    });

    test('同一明文两次加密产生不同密文（随机 nonce）', () async {
      const plaintext = 'same-secret';
      final a = await cipher.encrypt(plaintext, aad: 'x');
      final b = await cipher.encrypt(plaintext, aad: 'x');
      expect(a, isNot(b));
      expect(await cipher.decrypt(a, aad: 'x'), plaintext);
      expect(await cipher.decrypt(b, aad: 'x'), plaintext);
    });

    test('AAD 绑定归属：AAD 不匹配解密失败', () async {
      final encrypted = await cipher.encrypt('secret', aad: 'wechat.credentials');
      expect(
        () => cipher.decrypt(encrypted, aad: 'networkProxy.password'),
        throwsA(isA<CredentialDecryptException>()),
      );
    });

    test('GCM 篡改检测：密文任一字节改动 → 解密抛异常', () async {
      final encrypted = await cipher.encrypt('tamper-me', aad: 'mcp.accessToken');
      final payload = base64Decode(encrypted.substring(CredentialCipher.prefix.length));
      payload[payload.length - 1] ^= 0x01; // 篡改 tag 末字节
      final tampered =
          '${CredentialCipher.prefix}${base64Encode(payload)}';
      await expectLater(
        cipher.decrypt(tampered, aad: 'mcp.accessToken'),
        throwsA(
          isA<CredentialDecryptException>().having(
            (e) => e.reason,
            'reason',
            CredentialDecryptReason.failed,
          ),
        ),
      );
    });

    test('非 enc:v1: 旧值 isEncrypted=false（迁移前明文兼容）', () async {
      expect(cipher.isEncrypted('plain-text-old'), isFalse);
      expect(cipher.isEncrypted(''), isFalse);
    });

    test('主密钥不可用 → available=false，decrypt 抛 key_unavailable', () async {
      final unavailable =
          CredentialCipher(masterKeyStore: _UnavailableKeyStore());
      expect(await unavailable.available, isFalse);
      await expectLater(
        unavailable.decrypt('${CredentialCipher.prefix}AAA', aad: 'x'),
        throwsA(
          isA<CredentialDecryptException>().having(
            (e) => e.reason,
            'reason',
            CredentialDecryptReason.key_unavailable,
          ),
        ),
      );
    });

    test('主密钥懒生成并写回（首次 encrypt 生成、二次复用）', () async {
      final seeded = _SeededKeyStore(null);
      final c = CredentialCipher(masterKeyStore: seeded);
      await c.encrypt('first', aad: 'x');
      final keyAfterFirst = await seeded.read();
      expect(keyAfterFirst, isNotNull);
      await c.encrypt('second', aad: 'x');
      expect(await seeded.read(), keyAfterFirst); // 复用，不重新生成
    });

    test('前缀不符（not_encrypted）decrypt 抛异常', () async {
      await expectLater(
        cipher.decrypt('plain', aad: 'x'),
        throwsA(
          isA<CredentialDecryptException>().having(
            (e) => e.reason,
            'reason',
            CredentialDecryptReason.not_encrypted,
          ),
        ),
      );
    });
  });

  group('credential_json 字段级加解密', () {
    late CredentialCipher cipher;
    setUp(() {
      cipher = CredentialCipher(masterKeyStore: InMemoryMasterKeyStore());
    });

    test('单字段 encryptJsonField / decryptJsonField 往返 + 旧值直通', () async {
      const json = '{"password":"p@ss","username":"u"}';
      final encrypted = await encryptJsonField(
        json,
        'password',
        cipher,
        aad: 'networkProxy.password',
      );
      expect(encrypted, isNot(contains('p@ss')));
      expect(encrypted, contains(CredentialCipher.prefix));

      final decrypted = await decryptJsonField(
        encrypted,
        'password',
        cipher,
        aad: 'networkProxy.password',
      );
      expect(decrypted, json);

      // 旧明文直通（未加密不改动）。
      final passthrough = await decryptJsonField(
        json,
        'password',
        cipher,
        aad: 'networkProxy.password',
      );
      expect(passthrough, json);
    });

    test('单字段空值直通（幂等，不产生密文）', () async {
      const json = '{"password":"","username":"u"}';
      final encrypted = await encryptJsonField(json, 'password', cipher);
      expect(encrypted, json);
    });

    test('decryptJsonFieldFailClosed：解密失败置空（不返回明文/密文）', () async {
      const json = '{"password":"p@ss","username":"u"}';
      final encrypted = await encryptJsonField(json, 'password', cipher);
      // 仅篡改 JSON 内的密文载荷（保留 enc:v1: 前缀与合法 JSON 结构）
      // → decrypt 抛 failed → fail-closed 置空。
      final map = jsonDecode(encrypted) as Map<String, dynamic>;
      final val = map['password'] as String;
      map['password'] = val.substring(0, val.length - 4) + 'AAAA';
      final tampered = jsonEncode(map);
      final result = await decryptJsonFieldFailClosed(tampered, 'password', cipher);
      expect(result, isNot(contains('p@ss')));
      expect(result, contains('"password":""'));
    });

    test('微信聚合加解密往返（credentials + contextToken）', () async {
      const json =
          '{"wechat":{"credentials":{"token":"wx-token","appId":"a"},'
          '"chatContexts":[{"chatId":"c1","contextToken":"ctx-token"}]}}';
      final encrypted = await encryptWechatAggregate(json, cipher);
      expect(encrypted, isNot(contains('wx-token')));
      expect(encrypted, isNot(contains('ctx-token')));

      final decrypted = await decryptWechatAggregate(encrypted, cipher);
      expect(decrypted, json);
    });

    test('微信聚合已加密幂等（不重复加密）', () async {
      const json = '{"wechat":{"credentials":{"token":"t"}}}';
      final once = await encryptWechatAggregate(json, cipher);
      final twice = await encryptWechatAggregate(once, cipher);
      expect(twice, once);
    });

    test('MCP 聚合加解密往返（servers[].oauth 三字段）', () async {
      const json =
          '{"servers":[{"name":"s1","url":"http://x","oauth":{'
          '"accessToken":"at","refreshToken":"rt","registeredClientSecret":"cs",'
          '"clientId":"c","scopes":[]}}]}';
      final encrypted = await encryptMcpAggregate(json, cipher);
      expect(encrypted, isNot(contains('"at"')));
      expect(encrypted, isNot(contains('"rt"')));
      expect(encrypted, isNot(contains('"cs"')));

      // 逐字段解密还原。
      final map = jsonDecode(encrypted) as Map<String, dynamic>;
      final oauth =
          ((map['servers'] as List).first as Map)['oauth'] as Map;
      expect(await cipher.decrypt(oauth['accessToken'] as String, aad: 'mcp.accessToken'), 'at');
      expect(await cipher.decrypt(oauth['refreshToken'] as String, aad: 'mcp.refreshToken'), 'rt');
      expect(
        await cipher.decrypt(
          oauth['registeredClientSecret'] as String,
          aad: 'mcp.registeredClientSecret',
        ),
        'cs',
      );
    });

    test('MCP 聚合无 oauth / 空值直通', () async {
      const json = '{"servers":[{"name":"s1","url":"http://x"}]}';
      expect(await encryptMcpAggregate(json, cipher), json);
      expect(await encryptMcpAggregate('{"servers":[]}', cipher), '{"servers":[]}');
    });
  });

  group('credential_cipher_singleton', () {
    tearDown(() => debugSetCredentialCipher(null));

    test('默认返回生产实例；debugSetCredentialCipher 覆盖并可重置', () {
      expect(credentialCipher, isA<CredentialCipher>());
      final testCipher =
          CredentialCipher(masterKeyStore: InMemoryMasterKeyStore());
      debugSetCredentialCipher(testCipher);
      expect(credentialCipher, same(testCipher));
      debugSetCredentialCipher(null);
      expect(credentialCipher, isNot(same(testCipher)));
    });
  });
}
