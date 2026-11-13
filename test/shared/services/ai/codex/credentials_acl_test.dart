// 职责: 测试 Codex auth.json ACL 收紧（P0-C）— 幂等、不破坏功能、不抛异常。
// 说明: 真实 icacls / chmod 可能因环境（服务账户 / 权限）失败，函数仅记录
// 不抛，故此处断言「不抛 + 幂等 + 文件仍可用」。
// 关联文件:
//   lib/shared/services/ai/codex/credentials.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reveric/shared/services/ai/codex/credentials.dart';

void main() {
  test('ensureFileAcl 对临时文件不抛且幂等（Windows icacls / Unix chmod 600）',
      () async {
    final dir = await Directory.systemTemp.createTemp('reveric-codex-acl-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    });
    final file = File(p.join(dir.path, 'auth.json'));
    await file.writeAsString('{}');

    // 首次收紧（真实执行或失败均不抛）。
    await CodexCredentials.ensureFileAcl(file.path);
    // 进程内幂等收紧。
    await CodexCredentials.ensureFileAclOnce(file.path);

    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), '{}');
  });

  test('ensureFileAcl 对不存在文件也不抛（仅记录）', () async {
    final missing = File(
      p.join((await Directory.systemTemp.createTemp('reveric-codex-missing-')).path, 'nope.json'),
    );
    await CodexCredentials.ensureFileAcl(missing.path);
    expect(await missing.exists(), isFalse);
  });
}
