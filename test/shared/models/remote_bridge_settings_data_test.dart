// 职责: 验证远程桥接持久化快照的编解码与逐字段更新不互相覆盖
// 关联文件:
//   lib/shared/models/app_settings_aggregate_data.dart
//   lib/shared/providers/remote_bridge_providers.dart
// 遵循的 Rules:
//   .agents/rules/json.md
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/app_settings_aggregate_data.dart';

const _credentials = RemoteBridgeWechatCredentialsData(
  token: 'tok',
  baseUrl: 'https://example.test',
  accountId: 'bot',
  userId: 'usr',
);

const _chatContexts = <RemoteBridgeWechatChatContextData>[
  RemoteBridgeWechatChatContextData(chatId: 'chat_a', contextToken: 'ctx_a'),
];

void main() {
  group('RemoteBridgeSettingsData', () {
    test('defaults to disabled without credentials (P0-A 默认关闭)', () {
      const data = RemoteBridgeSettingsData.defaults;
      expect(data.wechat.enabled, isFalse);
      expect(data.wechat.remoteConfirmed, isFalse);
      expect(data.wechat.credentials, isNull);
      expect(data.wechat.chatContexts, isEmpty);
    });

    test('round-trips through encode/decode', () {
      const original = RemoteBridgeSettingsData(
        wechat: RemoteBridgeWechatData(
          enabled: false,
          credentials: _credentials,
          chatContexts: _chatContexts,
        ),
      );

      final decoded = RemoteBridgeSettingsData.decode(original.encode());

      expect(decoded.wechat.enabled, isFalse);
      expect(decoded.wechat.credentials?.token, 'tok');
      expect(decoded.wechat.credentials?.baseUrl, 'https://example.test');
      expect(decoded.wechat.credentials?.accountId, 'bot');
      expect(decoded.wechat.credentials?.userId, 'usr');
      expect(decoded.wechat.chatContexts, hasLength(1));
      expect(decoded.wechat.chatContexts.single.chatId, 'chat_a');
      expect(decoded.wechat.chatContexts.single.contextToken, 'ctx_a');
    });

    // 半个凭证无法登录：当作未登录处理，让用户重新扫码，而不是拿残缺凭证去起长轮询。
    test('partial credentials decode to null', () {
      final decoded = RemoteBridgeSettingsData.decode(
        '{"version":1,"wechat":{"enabled":true,'
        '"credentials":{"token":"tok","baseUrl":"https://example.test"}}}',
      );
      expect(decoded.wechat.credentials, isNull);
      expect(decoded.wechat.enabled, isTrue);
      // 旧 JSON 无 remoteConfirmed → 回落 fallback（默认 false），门禁未打开。
      expect(decoded.wechat.remoteConfirmed, isFalse);
    });

    test('malformed channel entry falls back instead of throwing', () {
      final decoded = RemoteBridgeSettingsData.decode(
        '{"version":1,"wechat":"not-an-object"}',
      );
      // fallback = defaults：默认关闭（P0-A）。
      expect(decoded.wechat.enabled, isFalse);
      expect(decoded.wechat.credentials, isNull);
      expect(decoded.wechat.chatContexts, isEmpty);
    });

    test('drops malformed chat context entries', () {
      final decoded = RemoteBridgeSettingsData.decode(
        '{"version":1,"wechat":{"chatContexts":['
        '{"chatId":"chat_a","contextToken":"ctx_a"},'
        '{"chatId":"chat_b"},"garbage"]}}',
      );
      expect(decoded.wechat.chatContexts, hasLength(1));
      expect(decoded.wechat.chatContexts.single.chatId, 'chat_a');
    });

    // 开关、凭证、上下文 token 是三条独立的写入路径，共用同一个 key；
    // 任何一条覆盖掉另外两条都会表现为「重启后要重新扫码」或「开关不记忆」。
    test('per-field updates keep the other fields intact', () {
      var data = RemoteBridgeSettingsData.defaults;

      data = data.copyWith(
        wechat: data.wechat.copyWith(credentials: _credentials),
      );
      data = data.copyWith(wechat: data.wechat.copyWith(enabled: false));
      data = data.copyWith(
        wechat: data.wechat.copyWith(chatContexts: _chatContexts),
      );

      expect(data.wechat.credentials?.token, 'tok');
      expect(data.wechat.enabled, isFalse);
      expect(data.wechat.chatContexts, hasLength(1));
    });

    test('clearing credentials keeps the enabled flag', () {
      const data = RemoteBridgeSettingsData(
        wechat: RemoteBridgeWechatData(
          enabled: false,
          credentials: _credentials,
          chatContexts: _chatContexts,
        ),
      );

      final cleared = data.copyWith(
        wechat: data.wechat.copyWith(
          credentials: null,
          chatContexts: const <RemoteBridgeWechatChatContextData>[],
        ),
      );

      expect(cleared.wechat.credentials, isNull);
      expect(cleared.wechat.chatContexts, isEmpty);
      expect(
        cleared.wechat.enabled,
        isFalse,
        reason: '掉线/登出与用户开关意图无关，重新扫码后应沿用原开关状态',
      );
    });
  });

  // P0-A A1 运行时门禁语义（远程默认关闭 + 历史配置不绕过 + 本地确认后打开）。
  group('RemoteBridgeWechatData 运行时门禁（P0-A.1 任务 4）', () {
    test('defaults.remoteConfirmed == false（无确认标记，门禁关闭）', () {
      expect(RemoteBridgeWechatData.defaults.remoteConfirmed, isFalse);
    });

    test('旧版本 enabled=true 无确认标记 → 门禁未打开（enabled && confirmed == false）', () {
      // 模拟历史持久化：enabled: true，但 JSON 无 remoteConfirmed 字段。
      final decoded = RemoteBridgeWechatData.fromJson({
        'enabled': true,
        // 无 'remoteConfirmed' 键 → 回落到 fallback（defaults）= false
      });
      expect(decoded.enabled, isTrue);
      expect(decoded.remoteConfirmed, isFalse);
      // 门禁判定：两者都为 true 才允许自动启动
      expect(decoded.enabled && decoded.remoteConfirmed, isFalse);
    });

    test('本地确认后门禁打开（enabled=true && remoteConfirmed=true）', () {
      final data = RemoteBridgeWechatData.fromJson({
        'enabled': true,
        'remoteConfirmed': true,
      });
      expect(data.enabled && data.remoteConfirmed, isTrue);
    });

    test('fromJson 缺省 remoteConfirmed 回落到 fallback 值', () {
      // 显式 fallback 有确认标记但 JSON 缺失 → 保留 fallback 值
      final fallback = RemoteBridgeWechatData(
        enabled: true,
        credentials: null,
        chatContexts: const [],
        remoteConfirmed: true,
      );
      final decoded = RemoteBridgeWechatData.fromJson({
        'enabled': false,
      }, fallback: fallback);
      expect(decoded.remoteConfirmed, isTrue);
    });

    test('toJson 往返保留 remoteConfirmed', () {
      final data = RemoteBridgeWechatData(
        enabled: true,
        credentials: null,
        chatContexts: const [],
        remoteConfirmed: true,
      );
      final json = data.toJson();
      expect(json['remoteConfirmed'], isTrue);
      final decoded = RemoteBridgeWechatData.fromJson(json);
      expect(decoded.remoteConfirmed, isTrue);
      expect(decoded.enabled, isTrue);
    });
  });
}
