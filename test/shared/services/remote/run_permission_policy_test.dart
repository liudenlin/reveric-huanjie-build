// 职责: P0-B.1 S1 — Run 能力正向授权策略单测。
//       逐项验证「允许的写作命令」（reviewedWriteOperations 全量）与
//       「高风险拒绝路径」（未知/未分类/外部执行/未审核写/scope 不足/
//       作品未绑定），以及 read 操作任意 scope 放行。
//       纯策略单测（无数据库/无 Flutter 绑定），可在 CI 直接运行。
// 关联文件:
//   lib/shared/services/remote/run_permission_policy.dart
//   lib/shared/services/remote/remote_authorization_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/remote/run_permission_policy.dart';

void main() {
  RunPolicyDecision eval(
    String command,
    String subcommand, {
    String? workId = 'w1',
    RunPolicyScope scope = RunPolicyScope.write,
  }) {
    return RunPermissionPolicy.evaluate(
      command: command,
      subcommand: subcommand,
      workId: workId,
      scope: scope,
    );
  }

  group('S1 允许的写作命令（逐项，正向白名单全量）', () {
    for (final op in RunPermissionPolicy.reviewedWorkWriteOperations) {
      test('作品域写允许: $op（write scope + 作品绑定）', () {
        final d = eval(op.split('.')[0], op.split('.')[1]);
        expect(d.isAllowed, isTrue, reason: '$op 应被允许');
        expect(d.operationType, RunOperationType.write,
            reason: '$op 是作品域写（操作类型必须为 write）');
      });
      test('作品域写允许: $op（all scope）', () {
        final d = eval(
          op.split('.')[0],
          op.split('.')[1],
          scope: RunPolicyScope.all,
        );
        expect(d.isAllowed, isTrue, reason: '$op 在 all scope 下应被允许');
      });
    }
    for (final op in RunPermissionPolicy.reviewedGlobalWriteOperations) {
      test('全局写允许: $op（write scope，无需作品绑定）', () {
        final d = eval(
          op.split('.')[0],
          op.split('.')[1],
          workId: null,
        );
        expect(d.isAllowed, isTrue, reason: '$op 全局写应被允许');
        expect(d.operationType, RunOperationType.globalWrite,
            reason: '$op 是全局写（操作类型必须为 globalWrite）');
      });
      test('全局写允许: $op（all scope）', () {
        final d = eval(
          op.split('.')[0],
          op.split('.')[1],
          workId: null,
          scope: RunPolicyScope.all,
        );
        expect(d.isAllowed, isTrue, reason: '$op 在 all scope 下应被允许');
      });
    }
  });

  group('S1 只读操作任意 scope 放行', () {
    for (final op in RunPermissionPolicy.readOperations) {
      test('read 允许: $op（read scope）', () {
        final d = eval(
          op.split('.')[0],
          op.split('.')[1],
          scope: RunPolicyScope.read,
        );
        expect(d.isAllowed, isTrue, reason: '$op 只读应放行');
        expect(d.operationType, RunOperationType.read);
      });
    }
  });

  group('S1 受控通知（P0-B.3 任务3：独立能力分类）', () {
    for (final op in RunPermissionPolicy.reviewedNotifyOperations) {
      test('notify 允许: $op（write scope）', () {
        final d = eval(op.split('.')[0], op.split('.')[1]);
        expect(d.isAllowed, isTrue, reason: '$op 受控通知应被允许');
        expect(d.operationType, RunOperationType.notify,
            reason: '$op 操作类型必须为 notify（独立分类）');
      });
      test('notify 允许: $op（all scope）', () {
        final d = eval(
          op.split('.')[0],
          op.split('.')[1],
          scope: RunPolicyScope.all,
        );
        expect(d.isAllowed, isTrue, reason: '$op 在 all scope 下应被允许');
      });
    }
    test('notify + read scope → deny scope_denied（通知是写入类能力）', () {
      final d = eval('notify', 'progress', scope: RunPolicyScope.read);
      expect(d.isAllowed, isFalse);
      expect(d.code, 'scope_denied');
    });
    test('notify 不要求作品绑定（无 workId）', () {
      final d = eval('notify', 'complete', workId: null);
      expect(d.isAllowed, isTrue);
      expect(d.operationType, RunOperationType.notify);
    });
    test('未知 notify 子命令 → deny unknown_subcommand', () {
      final d = eval('notify', 'bogus');
      expect(d.isAllowed, isFalse);
      expect(d.code, 'unknown_subcommand');
    });
  });

  group('S1 高风险拒绝路径', () {
    test('未知 command → deny unknown_subcommand', () {
      final d = eval('bogus', 'list');
      expect(d.isAllowed, isFalse);
      expect(d.code, 'unknown_subcommand');
    });

    test('已知 command 未知 subcommand → deny unknown_subcommand', () {
      final d = eval('stagings', 'bogus');
      expect(d.isAllowed, isFalse);
      expect(d.code, 'unknown_subcommand');
    });

    test('未分类（denied-codemode）子命令 → deny not_classified', () {
      for (final (command, subcommand) in const [
        ('mcp', 'list'),
        ('mcp', 'search'),
        ('mcp', 'describe'),
        ('settings', 'open'),
        ('map', 'draft'),
        ('assets', 'view-image'),
        ('files', 'view-image'),
        ('stagings', 'frames'),
        ('editing', 'frames'),
        ('ffmpeg', 'frames'),
      ]) {
        final d = eval(command, subcommand);
        expect(d.isAllowed, isFalse,
            reason: '$command.$subcommand 未分类应拒绝');
        expect(d.code, 'not_classified', reason: '$command.$subcommand');
      }
    });

    test('外部调用（mcp.call / files.remove / generation.*）→ deny requires_explicit_review',
        () {
      for (final op in const [
        'mcp.call',
        'files.remove',
        'production.generate-image',
        'production.generate-video',
        'production.generate-audio',
        'character.generate-avatar',
        'character.generate-photo',
        'item.generate-photo',
      ]) {
        final d = eval(op.split('.')[0], op.split('.')[1]);
        expect(d.isAllowed, isFalse, reason: '$op 外部调用应拒绝');
        expect(d.code, 'requires_explicit_review', reason: op);
      }
    });

    test('外部进程执行（ffmpeg.execute）→ deny requires_explicit_review', () {
      final d = eval('ffmpeg', 'execute');
      expect(d.isAllowed, isFalse);
      expect(d.code, 'requires_explicit_review');
    });

    test('未审核写（media/文件/安装）→ deny write_not_reviewed', () {
      for (final op in const [
        'assets.certify',
        'production.capture-panorama',
        'production.derive-view',
        'production.split-grid',
        'production.capture-frame',
        'production.separate-audio',
        'production.mute-video',
        'production.trim-video',
        'agent-skills.install',
      ]) {
        final d = eval(op.split('.')[0], op.split('.')[1]);
        expect(d.isAllowed, isFalse, reason: '$op 未审核写应拒绝');
        expect(d.code, 'write_not_reviewed', reason: op);
      }
    });

    test('write 操作 + read scope → deny scope_denied', () {
      final d = eval('stagings', 'write', scope: RunPolicyScope.read);
      expect(d.isAllowed, isFalse);
      expect(d.code, 'scope_denied');
    });

    test('write 操作 + 空 workId → deny work_not_bound', () {
      final d = eval('stagings', 'write', workId: '');
      expect(d.isAllowed, isFalse);
      expect(d.code, 'work_not_bound');
    });

    test('write 操作 + null workId → deny work_not_bound（P0-B.2：不得把未绑定当 Job 绑定放行）', () {
      final d = eval('stagings', 'write', workId: null);
      expect(d.isAllowed, isFalse,
          reason: '第 4 维（作品归属）必须真实生效：未绑定作品不得放行写操作');
      expect(d.code, 'work_not_bound');
    });

    test('read 操作 + read scope → 允许（只读安全）', () {
      final d = eval('files', 'read-text', scope: RunPolicyScope.read);
      expect(d.isAllowed, isTrue);
    });

    // P0-B.3 任务2：作品域写与全局写分开分类。
    test('全局写（styles.create）+ read scope → deny scope_denied', () {
      final d = eval('styles', 'create', scope: RunPolicyScope.read);
      expect(d.isAllowed, isFalse);
      expect(d.code, 'scope_denied');
    });

    test('全局写（styles.create）+ 空 workId → 允许（无需作品绑定）', () {
      final d = eval('styles', 'create', workId: '');
      expect(d.isAllowed, isTrue,
          reason: '全局写无作品归属，不要求 workId（P0-B.3 任务2 独立分类）');
      expect(d.operationType, RunOperationType.globalWrite);
    });

    test('作品域写要求 workId，全局写不要求（分类不混淆）', () {
      // 作品域写 + 空 workId → work_not_bound。
      final workWrite = eval('stagings', 'write', workId: '');
      expect(workWrite.isAllowed, isFalse);
      expect(workWrite.code, 'work_not_bound');
      // 全局写 + 空 workId → 放行（独立分类）。
      final globalWrite = eval('agent-rules', 'create', workId: '');
      expect(globalWrite.isAllowed, isTrue);
      expect(globalWrite.operationType, RunOperationType.globalWrite);
    });

    test('作品域读操作（files.read-text）不要求 workId（只读任意 scope 放行）', () {
      final d = eval('files', 'read-text', workId: null);
      expect(d.isAllowed, isTrue);
      expect(d.operationType, RunOperationType.read);
    });
  });

  group('S1 策略覆盖度（审计一致性）', () {
    test('白名单 ⊆ 写分类（作品域 ∪ 全局）', () {
      for (final op in RunPermissionPolicy.reviewedWriteOperations) {
        final t = RunPermissionPolicy.classify(
          op.split('.')[0],
          op.split('.')[1],
        );
        expect(
          t == RunOperationType.write || t == RunOperationType.globalWrite,
          isTrue,
          reason: '$op 必须在写分类内（白名单不漂移）',
        );
      }
    });
    test('作品域白名单 ⊆ 作品域写分类', () {
      for (final op in RunPermissionPolicy.reviewedWorkWriteOperations) {
        expect(RunPermissionPolicy.classify(op.split('.')[0], op.split('.')[1]),
            RunOperationType.write,
            reason: '$op 必须在作品域写分类内');
      }
    });
    test('全局白名单 ⊆ 全局写分类', () {
      for (final op in RunPermissionPolicy.reviewedGlobalWriteOperations) {
        expect(
            RunPermissionPolicy.classify(op.split('.')[0], op.split('.')[1]),
            RunOperationType.globalWrite,
            reason: '$op 必须在全局写分类内（不得混入作品域写）');
      }
    });
    test('作品域写与全局写互不重叠', () {
      final overlap =
          RunPermissionPolicy.reviewedWorkWriteOperations.intersection(
        RunPermissionPolicy.reviewedGlobalWriteOperations,
      );
      expect(overlap, isEmpty, reason: '作品域写与全局写不得重叠');
    });
    test('每个已分类子命令都被正确分类', () {
      for (final op in RunPermissionPolicy.readOperations) {
        expect(RunPermissionPolicy.classify(op.split('.')[0], op.split('.')[1]),
            RunOperationType.read);
      }
      for (final op in RunPermissionPolicy.workWriteOperations) {
        expect(RunPermissionPolicy.classify(op.split('.')[0], op.split('.')[1]),
            RunOperationType.write);
      }
      for (final op in RunPermissionPolicy.globalWriteOperations) {
        expect(RunPermissionPolicy.classify(op.split('.')[0], op.split('.')[1]),
            RunOperationType.globalWrite);
      }
      for (final op in RunPermissionPolicy.notifyOperations) {
        expect(RunPermissionPolicy.classify(op.split('.')[0], op.split('.')[1]),
            RunOperationType.notify);
      }
    });
    // P0-B.3 任务3：notify 独立分类，不混入作品域/全局写，也不做作品归属校验。
    test('notify 独立分类：不混入作品域写/全局写/作品域资源操作', () {
      for (final op in RunPermissionPolicy.reviewedNotifyOperations) {
        expect(RunPermissionPolicy.reviewedWorkWriteOperations, isNot(contains(op)),
            reason: '$op 不是作品域写');
        expect(RunPermissionPolicy.reviewedGlobalWriteOperations, isNot(contains(op)),
            reason: '$op 不是全局写');
        expect(RunPermissionPolicy.workScopedOperations, isNot(contains(op)),
            reason: '$op 不是作品域资源操作（通知绑定 Job 会话）');
      }
    });
    // P0-B.3 任务2：作品域资源操作集合须被服务层用于归属校验，且与
    // 已分类的作品域操作一致（不漂移）。
    test('workScopedOperations 覆盖全部作品域资源操作', () {
      // 作品域读操作全部纳入。
      for (final op in const [
        'stagings.schema',
        'stagings.presets',
        'stagings.sample',
        'stagings.list',
        'stagings.read',
        'editing.list',
        'editing.read',
        'assets.list',
        'assets.read',
        'files.list',
        'files.read-text',
        'files.read-video-metadata',
        'files.read-audio-metadata',
      ]) {
        expect(RunPermissionPolicy.workScopedOperations, contains(op),
            reason: '$op 是作品域读，须纳入作品域资源操作集合');
      }
      // 作品域写操作全部纳入。
      for (final op in RunPermissionPolicy.reviewedWorkWriteOperations) {
        expect(RunPermissionPolicy.workScopedOperations, contains(op),
            reason: '$op 是作品域写，须纳入作品域资源操作集合');
      }
      // 全局写操作不纳入（无作品归属）。
      for (final op in RunPermissionPolicy.reviewedGlobalWriteOperations) {
        expect(RunPermissionPolicy.workScopedOperations, isNot(contains(op)),
            reason: '$op 是全局写，不得纳入作品域资源操作集合');
      }
    });
  });
}
