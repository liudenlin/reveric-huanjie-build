// 职责: P0-B.3 任务3 — 远程 Run notify 受控通知安全控制单测。
//       验证脱敏（token/api key/secret）、长度截断、频率上限、目标字段违规
//       检测（不得指定任意目标用户/渠道）、内容超长违规检测。
//       纯 Dart 单测，无 Flutter/数据库依赖，可在 CI 直接运行。
// 关联文件:
//   lib/shared/services/remote/notify_controls.dart
//   lib/shared/services/remote/remote_authorization_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/remote/notify_controls.dart';

void main() {
  group('redactNotifyContent（敏感信息脱敏）', () {
    test('token/api key/secret/password 键值对 → <redacted>', () {
      expect(redactNotifyContent('token=abc123'), 'token=<redacted>');
      expect(redactNotifyContent('api_key: abc123'), 'api_key: <redacted>');
      expect(redactNotifyContent('secret=xyz'), 'secret=<redacted>');
      expect(redactNotifyContent('password=pw1'), 'password=<redacted>');
      expect(
        redactNotifyContent('Bearer abc.def.ghi'),
        'Bearer <redacted>',
      );
    });

    test('非敏感内容原样保留（进度/提示文本）', () {
      expect(redactNotifyContent('进度 40%：正在生成本章'), '进度 40%：正在生成本章');
      expect(redactNotifyContent(''), '');
    });

    test('混合内容：敏感键脱敏、其余保留', () {
      final out = redactNotifyContent('完成。api_key=sk-123 剩余 2 步');
      expect(out, '完成。api_key=<redacted> 剩余 2 步');
    });
  });

  group('truncateNotifyContent（长度截断）', () {
    test('未超长 → 原样返回', () {
      expect(truncateNotifyContent('short', 2000), 'short');
    });
    test('超长 → 截断到 maxLength', () {
      final long = 'x' * 3000;
      final out = truncateNotifyContent(long, notifyMaxContentLength);
      expect(out.length, notifyMaxContentLength);
    });
    test('maxLength 为 0 → 空串', () {
      expect(truncateNotifyContent('abc', 0), '');
    });
  });

  group('notifyFrequencyAllowed（频率上限）', () {
    test('窗口内未达上限 → 放行', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final recent = [
        now.subtract(const Duration(seconds: 5)),
        now.subtract(const Duration(seconds: 10)),
      ];
      expect(notifyFrequencyAllowed(recent, now), isTrue);
    });
    test('窗口内达到上限 → 拒绝', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final recent = List.generate(
        notifyMaxPerWindow,
        (i) => now.subtract(Duration(seconds: i)),
      );
      expect(notifyFrequencyAllowed(recent, now), isFalse);
    });
    test('窗口外的旧记录不计数', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final recent = [
        now.subtract(const Duration(minutes: 2)),
        now.subtract(const Duration(minutes: 3)),
      ];
      expect(notifyFrequencyAllowed(recent, now), isTrue);
    });
    test('空记录 → 放行', () {
      expect(notifyFrequencyAllowed([], DateTime.now()), isTrue);
    });
  });

  group('notifyTargetViolation（禁止指定任意目标）', () {
    test('未指定目标 → 无违规', () {
      expect(
        notifyTargetViolation(const {
          'command': 'notify',
          'subcommand': 'progress',
          'options': {'content': '40%'},
        }),
        isNull,
      );
    });
    test('指定 target_chat_id → 违规', () {
      expect(
        notifyTargetViolation(const {
          'command': 'notify',
          'subcommand': 'progress',
          'options': {'content': '40%', 'target_chat_id': 'wxid_b'},
        }),
        contains('notify_target_forbidden'),
      );
    });
    test('指定 channel / chat_id / user_id（多种字段名）→ 违规', () {
      for (final key in const [
        'channel',
        'channel_type',
        'chat_id',
        'user_id',
        'chatId',
        'userId',
      ]) {
        expect(
          notifyTargetViolation({
            'command': 'notify',
            'subcommand': 'error',
            'options': {'content': 'boom', key: 'x'},
          }),
          isNotNull,
          reason: '$key 指定目标应视为违规',
        );
      }
    });
    test('顶层指定目标（非 options）→ 违规', () {
      expect(
        notifyTargetViolation(const {
          'command': 'notify',
          'subcommand': 'progress',
          'target_chat_id': 'wxid_b',
          'options': {'content': '40%'},
        }),
        isNotNull,
      );
    });
  });

  group('notifyLengthViolation（内容超长）', () {
    test('未超长 → 无违规', () {
      expect(
        notifyLengthViolation(const {
          'command': 'notify',
          'subcommand': 'progress',
          'options': {'content': 'short'},
        }),
        isNull,
      );
    });
    test('超长 → 违规', () {
      expect(
        notifyLengthViolation({
          'command': 'notify',
          'subcommand': 'progress',
          'options': {'content': 'x' * (notifyMaxContentLength + 1)},
        }),
        contains('notify_too_long'),
      );
    });
    test('恰好等于上限 → 无违规', () {
      expect(
        notifyLengthViolation({
          'command': 'notify',
          'subcommand': 'progress',
          'options': {'content': 'x' * notifyMaxContentLength},
        }),
        isNull,
      );
    });
    test('无 content → 无违规', () {
      expect(
        notifyLengthViolation(const {
          'command': 'notify',
          'subcommand': 'progress',
          'options': <String, dynamic>{},
        }),
        isNull,
      );
    });
  });
}
