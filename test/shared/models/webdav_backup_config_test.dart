// 职责: 验证 WebDAV 备份配置的标准化与安全校验。
// 关联文件:
//   lib/shared/models/webdav_backup_config.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/webdav_backup_config.dart';

void main() {
  test('normalizes the server URL and remote directory', () {
    final config = const WebDavBackupConfig(
      enabled: true,
      serverUrl: ' https://dav.example.com/root ',
      username: ' author ',
      password: 'secret',
      remoteDirectory: r'\Reveric\Backups\',
    ).normalized();

    expect(config.serverUrl, 'https://dav.example.com/root/');
    expect(config.username, 'author');
    expect(config.remoteDirectory, '/Reveric/Backups');
    expect(config.validate(), isNull);
  });

  test('requires TLS on remote endpoints but allows loopback HTTP', () {
    // P0-D B2：远程端点强制 TLS —— 明文 http 仅允许本机回环。
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
    expect(
      const WebDavBackupConfig(
        enabled: true,
        serverUrl: 'http://localhost:8080/dav',
        username: 'author',
        password: 'secret',
      ).validate(),
      isNull,
    );
    expect(
      const WebDavBackupConfig(
        enabled: true,
        serverUrl: 'ftp://dav.example.com',
        username: 'author',
      ).validate(),
      WebDavConfigIssue.invalidServerUrl,
    );
    expect(
      const WebDavBackupConfig(
        enabled: true,
        serverUrl: 'https://dav.example.com',
        username: 'author',
        password: 'secret',
        remoteDirectory: '/../Backups',
      ).validate(),
      WebDavConfigIssue.invalidRemoteDirectory,
    );
    expect(
      const WebDavBackupConfig(
        enabled: true,
        serverUrl: 'https://dav.example.com',
        username: 'author',
      ).validate(),
      WebDavConfigIssue.missingPassword,
    );
  });

  test('disabled configuration does not require credentials', () {
    expect(const WebDavBackupConfig().validate(), isNull);
    expect(const WebDavBackupConfig().normalized().serverUrl, isEmpty);
  });
}
