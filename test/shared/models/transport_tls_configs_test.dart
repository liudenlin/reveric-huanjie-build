// 职责: 验证传输层 TLS 收紧在各配置接入点的落地 —— 远程明文 http 拒绝、
// https 与回环 http 豁免（P0-D B2）。
// 关联文件:
//   lib/shared/models/webdav_backup_config.dart
//   lib/shared/models/object_storage_config.dart
//   lib/shared/models/mcp/config.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/mcp/config.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/models/webdav_backup_config.dart';

void main() {
  group('WebDavBackupConfig TLS', () {
    test('rejects remote cleartext http and allows loopback', () {
      expect(
        const WebDavBackupConfig(
          enabled: true,
          serverUrl: 'http://dav.example.com',
          username: 'author',
          password: 'secret',
        ).validate(),
        WebDavConfigIssue.insecureServerUrl,
      );
      expect(
        const WebDavBackupConfig(
          enabled: true,
          serverUrl: 'http://127.0.0.1:8080/dav',
          username: 'author',
          password: 'secret',
        ).validate(),
        isNull,
      );
    });
  });

  group('ObjectStorageConfig TLS', () {
    ObjectStorageConfig os({String? endpoint, String publicBaseUrl = ''}) =>
        ObjectStorageConfig(
          endpoint: endpoint ?? 'https://s3.example.com',
          region: 'us-east-1',
          bucket: 'bucket',
          accessKeyId: 'key',
          secretAccessKey: 'secret',
          publicBaseUrl: publicBaseUrl,
        );

    test('rejects remote cleartext endpoint', () {
      expect(
        os(endpoint: 'http://s3.example.com').validate(),
        ObjectStorageConfigIssue.insecure_endpoint,
      );
    });

    test('allows loopback endpoint', () {
      expect(
        os(endpoint: 'http://127.0.0.1:9000').validate(),
        isNull,
      );
    });

    test('rejects remote cleartext public base URL', () {
      expect(
        os(publicBaseUrl: 'http://cdn.example.com').validate(),
        ObjectStorageConfigIssue.insecure_public_base_url,
      );
    });

    test('allows loopback public base URL', () {
      expect(
        os(publicBaseUrl: 'http://127.0.0.1:9000').validate(),
        isNull,
      );
    });
  });

  group('McpHttpConfig TLS', () {
    test('rejects remote cleartext http', () {
      expect(
        () => McpHttpConfig(url: 'http://example.test/mcp'),
        throwsFormatException,
      );
    });

    test('allows https and loopback http', () {
      expect(McpHttpConfig(url: 'https://example.test/mcp'), isNotNull);
      expect(McpHttpConfig(url: 'http://127.0.0.1:8080/mcp'), isNotNull);
    });
  });
}
