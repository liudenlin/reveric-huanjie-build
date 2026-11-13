// 职责: P0-B.3 任务2 — 作品域 Run 写操作目标资源归属校验器单测。
//       验证 DefaultRunResourceVerifier 的目标作品 ID 提取（字段名兼容）、
//       跨作品拒绝、归属一致放行、未声明目标放行、无可信作品但显式目标拒绝，
//       以及服务层注入校验器后的整体行为（跨作品端到端拒绝在
//       remote_execution_gate_test.dart 覆盖）。纯 Dart 单测，无数据库。
// 关联文件:
//   lib/shared/services/remote/run_resource_verifier.dart
//   lib/shared/services/remote/remote_authorization_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/remote/run_resource_verifier.dart';

void main() {
  group('extractTargetWorkId（字段名兼容）', () {
    test('顶层 novelId / novel_id / workId / work_id 均可解析', () {
      expect(extractTargetWorkId({'novelId': 'w1'}), 'w1');
      expect(extractTargetWorkId({'novel_id': 'w1'}), 'w1');
      expect(extractTargetWorkId({'workId': 'w1'}), 'w1');
      expect(extractTargetWorkId({'work_id': 'w1'}), 'w1');
    });

    test('options 内的目标作品 ID 可解析', () {
      expect(
        extractTargetWorkId({
          'command': 'stagings',
          'subcommand': 'write',
          'options': {'novelId': 'w2'},
        }),
        'w2',
      );
    });

    test('未声明 / 空值 / 非字符串 → null', () {
      expect(extractTargetWorkId(null), isNull);
      expect(extractTargetWorkId({}), isNull);
      expect(extractTargetWorkId({'novelId': ''}), isNull);
      expect(extractTargetWorkId({'novelId': 123}), isNull);
      expect(
        extractTargetWorkId({
          'options': {'novelId': ''},
        }),
        isNull,
      );
    });

    test('顶层优先于 options（避免误读 command/subcommand 结构键）', () {
      expect(
        extractTargetWorkId({
          'novelId': 'w1',
          'options': {'novelId': 'w2'},
        }),
        'w1',
      );
    });
  });

  group('DefaultRunResourceVerifier（归属判定）', () {
    const verifier = DefaultRunResourceVerifier();

    test('跨作品：显式目标 != 可信作品 → 拒绝', () async {
      expect(
        await verifier.verifyWorkResource(
          workId: 'work-a',
          command: 'stagings',
          subcommand: 'write',
          toolArguments: const {
            'options': {'novelId': 'work-b', 'id': 's1'},
          },
        ),
        isFalse,
      );
    });

    test('归属一致：显式目标 == 可信作品 → 放行', () async {
      expect(
        await verifier.verifyWorkResource(
          workId: 'work-a',
          command: 'stagings',
          subcommand: 'write',
          toolArguments: const {
            'options': {'novelId': 'work-a', 'id': 's1'},
          },
        ),
        isTrue,
      );
    });

    test('未显式声明目标作品 → 放行（资源绑定可信作品）', () async {
      expect(
        await verifier.verifyWorkResource(
          workId: 'work-a',
          command: 'editing',
          subcommand: 'apply',
          toolArguments: const {'options': {'id': 'e1'}},
        ),
        isTrue,
      );
    });

    test('显式目标但无可信作品（workId null/空）→ 拒绝（归属不可证）', () async {
      expect(
        await verifier.verifyWorkResource(
          workId: null,
          command: 'files',
          subcommand: 'read-text',
          toolArguments: const {
            'options': {'novelId': 'work-b', 'path': 'c/1.md'},
          },
        ),
        isFalse,
      );
      expect(
        await verifier.verifyWorkResource(
          workId: '',
          command: 'files',
          subcommand: 'read-text',
          toolArguments: const {
            'options': {'novelId': 'work-b', 'path': 'c/1.md'},
          },
        ),
        isFalse,
      );
    });

    test('无可信作品且未显式目标 → 放行（本地上下文，资源无跨作品目标）', () async {
      expect(
        await verifier.verifyWorkResource(
          workId: null,
          command: 'files',
          subcommand: 'read-text',
          toolArguments: const {'options': {'path': 'c/1.md'}},
        ),
        isTrue,
      );
    });

    test('work_id（下划线）字段名同样触发跨作品拒绝', () async {
      expect(
        await verifier.verifyWorkResource(
          workId: 'work-a',
          command: 'novel',
          subcommand: 'add-to-library',
          toolArguments: const {'options': {'work_id': 'work-b'}},
        ),
        isFalse,
      );
    });
  });
}
