// 职责: 验证 P0-D D2 渠道适配器统一授权架构约束 ——
//       渠道适配器不得自行判定授权（deny-by-default 契约），统一授权由上层
//       coordinator / bridge 层经 RemoteAuthorizationService 完成。此测试锁定
//       默认拒绝，防止未来渠道误 override 为放行导致「渠道自行判定」不一致。
// 关联文件:
//   lib/shared/services/remote/channel_adapter.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/remote/channel_adapter.dart';

/// 最小适配器桩 —— 仅用于验证 BaseChannelAdapter 的授权契约。
class _StubAdapter extends BaseChannelAdapter {
  @override
  String get channelType => 'stub';
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  bool isRunning() => false;
  @override
  Future<InboundMessage?> consumeOne() async => null;
  @override
  Future<SendResult> send(OutboundMessage message) async =>
      SendResult.success();
  @override
  String? validateConfig() => null;
  @override
  AdapterStatus status() =>
      const AdapterStatus(channelType: 'stub', running: false);
}

void main() {
  group('BaseChannelAdapter — 授权 deny-by-default 契约（P0-D D2）', () {
    test('默认 isAuthorized 返回 false（无授权记录/未接入统一授权 → 拒绝）',
        () {
      final adapter = _StubAdapter();
      expect(adapter.isAuthorized('any_user', 'any_chat'), isFalse);
    });

    test('任意身份均默认拒绝（渠道不得默认放行）', () {
      final adapter = _StubAdapter();
      expect(adapter.isAuthorized('', ''), isFalse);
      expect(adapter.isAuthorized('user1', 'chat1'), isFalse);
      expect(adapter.isAuthorized('user2', 'chat2'), isFalse);
    });

    test('授权判定不由适配器持有 —— 统一经上层 RemoteAuthorizationService '
        '（channel_adapter 不引用授权服务/授权表）', () {
      // 架构断言：适配器层不得自行判定授权，消息准入由 coordinator/bridge
      // 层经 RemoteAuthorizationService.isMessageAuthorized 完成（A1/A2）。
      // 若未来渠道需授权判断，不得 override isAuthorized 自行判定，而应
      // 依赖上层统一拦截。此处以「基类无授权逻辑」佐证契约。
      final adapter = _StubAdapter();
      expect(adapter.isAuthorized('u', 'c'), isFalse,
          reason: '渠道适配器必须保持 deny-by-default，授权统一经上层服务');
    });
  });
}
