// 职责: 验证 AssistantCoordinator 端到端编排 — handler 注册、入站分发、兜底文案路径
// 关联文件:
//   lib/shared/services/ai/assistant/coordinator.dart
//   lib/shared/services/remote/remote_bridge_service.dart
//   lib/shared/database/daos/assistant_session_dao.dart
//   lib/shared/services/ai/prompts/ai_prompt_service.dart
//
// 说明：不验证真实 LLM turn（需 ProviderClient + HTTP），只覆盖 coordinator 的
// wiring 与失败兜底分支——这是 PR-3「onInboundMessage → Assistant turn → text block
// 回微信」中可自动验证的部分；剩余 happy-path 由方案 §6 的手动测试覆盖。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/assistant/coordinator.dart';
import 'package:reveric/shared/services/ai/usage_service.dart';
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/services/remote/channel_adapter.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';
import 'package:reveric/shared/services/remote/remote_bridge_service.dart';

const _testChannelType = 'wechat';
const _testChatId = 'wxid_alice';
const _testModel = 'fake-chat';

final _fakeProvider = AiProvider(
  audioModels: const [],
  videoModels: const [],
  id: 'fake_provider',
  name: 'Fake Provider',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: const [_testModel],
  imageModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

InboundMessage _inbound({
  String text = '你好',
  String chatId = _testChatId,
  String? displayName,
  String? userId,
}) {
  return InboundMessage(
    messageId: 'm_${DateTime.now().microsecondsSinceEpoch}',
    address: ChannelAddress(
      channelType: _testChannelType,
      chatId: chatId,
      userId: userId,
      displayName: displayName,
    ),
    text: text,
    timestamp: DateTime.now().millisecondsSinceEpoch,
  );
}

/// 重写 [RemoteBridgeService] 的出站/通知方法，记录调用而不触达 adapter。
class _RecordingBridge extends RemoteBridgeService {
  _RecordingBridge();

  final List<(String chatId, String text)> sentMessages = [];
  final List<String> processingStartCalls = [];
  final List<String> processingEndCalls = [];

  @override
  Future<bool> sendToUser(String chatId, String text) async {
    sentMessages.add((chatId, text));
    return true;
  }

  @override
  Future<void> notifyProcessingStart(String chatId) async {
    processingStartCalls.add(chatId);
  }

  @override
  Future<void> notifyProcessingEnd(String chatId) async {
    processingEndCalls.add(chatId);
  }
}

Future<Map<String, dynamic>> _stubStartJob(
  String novelId,
  String seed, {
  required String chatId,
  required String channelType,
  String? userId,
}) async => {'ok': false, 'error': 'start job stub'};

Future<Map<String, dynamic>> _stubJobStatus(
  String jobId, {
  required String chatId,
  required String channelType,
}) async => {'ok': false, 'error': 'job status stub'};

Future<Map<String, dynamic>> _stubSendToJob(
  String jobId,
  String text, {
  required String chatId,
  required String channelType,
  String? userId,
}) async => {'ok': false, 'error': 'send to job stub'};

Future<Map<String, dynamic>> _stubCreateNovel(
  Map<String, dynamic> novel,
) async => {'ok': false, 'error': 'create novel stub'};

Future<Map<String, dynamic>> _stubEditNovel(
  String novelId,
  Map<String, dynamic> fields,
) async => {'ok': false, 'error': 'edit novel stub'};

Future<Map<String, dynamic>> _stubListChapters(String novelId) async => {
  'ok': false,
  'error': 'list chapters stub',
};

void main() {
  late AppDatabase db;
  late _RecordingBridge bridge;
  late AssistantCoordinator coordinator;
  late List<String> capturedSessionIds;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
    bridge = _RecordingBridge();
    capturedSessionIds = <String>[];
  });

  tearDown(() async {
    coordinator.stop();
    bridge.dispose();
    await db.close();
  });

  group('AssistantCoordinator.start/stop', () {
    test('start registers inbound handler on bridge', () {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
        // 现有用例均为「本地执行」语义（不注入授权），显式声明本地模式；
        // 远程模式（默认 localMode=false）缺授权会 fail-closed 拒绝。
        localMode: true,
      );
      expect(bridge.onInboundMessage, isNull);

      coordinator.start();
      expect(bridge.onInboundMessage, isNotNull);

      // 重复 start 是 no-op（不抛错、不重复注册）
      coordinator.start();
      coordinator.start();
    });

    test('stop unregisters inbound handler', () {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
        // 现有用例均为「本地执行」语义（不注入授权），显式声明本地模式；
        // 远程模式（默认 localMode=false）缺授权会 fail-closed 拒绝。
        localMode: true,
      );
      coordinator.start();
      expect(bridge.onInboundMessage, isNotNull);

      coordinator.stop();
      expect(bridge.onInboundMessage, isNull);

      // 重复 stop 是 no-op
      coordinator.stop();
    });

    test('stop is no-op when never started', () {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
        // 现有用例均为「本地执行」语义（不注入授权），显式声明本地模式；
        // 远程模式（默认 localMode=false）缺授权会 fail-closed 拒绝。
        localMode: true,
      );
      coordinator.stop(); // 不抛错
      expect(bridge.onInboundMessage, isNull);
    });
  });

  group('AssistantCoordinator._handleInbound', () {
    test('empty inbound text is ignored — no processing, no send', () async {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
        // 现有用例均为「本地执行」语义（不注入授权），显式声明本地模式；
        // 远程模式（默认 localMode=false）缺授权会 fail-closed 拒绝。
        localMode: true,
      );
      coordinator.start();

      await bridge.onInboundMessage!(_inbound(text: '   \n  '));

      expect(bridge.processingStartCalls, isEmpty);
      expect(bridge.processingEndCalls, isEmpty);
      expect(bridge.sentMessages, isEmpty);
    });

    test(
      'no chat model configured → fallback message + processing lifecycle',
      () async {
        coordinator = AssistantCoordinator(
          bridge: bridge,
          dao: db.assistantSessionDao,
          inboxDao: db.assistantInboxDao,
          aiPromptService: AiPromptService(),
          usageService: UsageService(appDatabase: db),
          clientFactory:
              ({
                required String providerId,
                required String model,
                required String sessionId,
              }) async {
                throw StateError(
                  'should not be called when no model configured',
                );
              },
          readAiSettings: () => const AiSettings(), // 无 providers
          listNovels: () async => const [],
          startJob: _stubStartJob,
          jobStatus: _stubJobStatus,
          sendToJob: _stubSendToJob,
          createNovel: _stubCreateNovel,
          editNovel: _stubEditNovel,
          listChapters: _stubListChapters,
          // 本地执行语义（不注入授权），显式声明本地模式；远程模式缺授权 fail-closed。
          localMode: true,
        );
        coordinator.start();

        await bridge.onInboundMessage!(_inbound(text: '列出小说'));

        expect(bridge.processingStartCalls, [_testChatId]);
        expect(bridge.processingEndCalls, [_testChatId]);
        expect(bridge.sentMessages, hasLength(1));
        expect(bridge.sentMessages.last.$1, _testChatId);
        expect(bridge.sentMessages.last.$2, contains('尚未配置默认聊天模型'));
      },
    );

    test(
      'clientFactory throws → friendly error fallback + processing lifecycle',
      () async {
        coordinator = AssistantCoordinator(
          bridge: bridge,
          dao: db.assistantSessionDao,
          inboxDao: db.assistantInboxDao,
          aiPromptService: AiPromptService(),
          usageService: UsageService(appDatabase: db),
          clientFactory:
              ({
                required String providerId,
                required String model,
                required String sessionId,
              }) async {
                throw StateError('boom: client init failed');
              },
          readAiSettings: () => AiSettings(providers: [_fakeProvider]),
          listNovels: () async => const [],
          startJob: _stubStartJob,
          jobStatus: _stubJobStatus,
          sendToJob: _stubSendToJob,
          createNovel: _stubCreateNovel,
          editNovel: _stubEditNovel,
          listChapters: _stubListChapters,
          // 本地执行语义（不注入授权），显式声明本地模式；远程模式缺授权 fail-closed。
          localMode: true,
        );
        coordinator.start();

        await bridge.onInboundMessage!(_inbound(text: '列出小说'));

        expect(bridge.processingStartCalls, [_testChatId]);
        expect(bridge.processingEndCalls, [_testChatId]);
        expect(bridge.sentMessages, hasLength(1));
        expect(bridge.sentMessages.last.$1, _testChatId);
        expect(bridge.sentMessages.last.$2, contains('抱歉'));
      },
    );

    test(
      'two inbound turns on same chatId → session reused (same id)',
      () async {
        var clientCallCount = 0;
        coordinator = AssistantCoordinator(
          bridge: bridge,
          dao: db.assistantSessionDao,
          inboxDao: db.assistantInboxDao,
          aiPromptService: AiPromptService(),
          usageService: UsageService(appDatabase: db),
          clientFactory:
              ({
                required String providerId,
                required String model,
                required String sessionId,
              }) async {
                clientCallCount += 1;
                // 捕获每次 turn 看到的 sessionId，验证两次相同
                capturedSessionIds.add(sessionId);
                throw StateError('intentional failure for test');
              },
          readAiSettings: () => AiSettings(providers: [_fakeProvider]),
          listNovels: () async => const [],
          startJob: _stubStartJob,
          jobStatus: _stubJobStatus,
          sendToJob: _stubSendToJob,
          createNovel: _stubCreateNovel,
          editNovel: _stubEditNovel,
          listChapters: _stubListChapters,
          // 本地执行语义（不注入授权），显式声明本地模式；远程模式缺授权 fail-closed。
          localMode: true,
        );
        coordinator.start();

        await bridge.onInboundMessage!(_inbound(text: 'first'));
        await bridge.onInboundMessage!(_inbound(text: 'second'));

        // 两次都触发 clientFactory（每次 turn 都新建 client）
        expect(clientCallCount, 2);
        // 两次都只发送各自的失败兜底消息 → 共 2 条
        expect(bridge.sentMessages, hasLength(2));
        // 同 chatId 复用同一 session（getOrCreateByChat 幂等）
        expect(capturedSessionIds, hasLength(2));
        expect(
          capturedSessionIds.toSet().length,
          1,
          reason: 'same chatId must resolve to same sessionId',
        );
      },
    );

    test('cross-chatId messages resolve to different sessions', () async {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              capturedSessionIds.add(sessionId);
              throw StateError('fail');
            },
        readAiSettings: () => AiSettings(providers: [_fakeProvider]),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
        // 现有用例均为「本地执行」语义（不注入授权），显式声明本地模式；
        // 远程模式（默认 localMode=false）缺授权会 fail-closed 拒绝。
        localMode: true,
      );
      coordinator.start();

      await bridge.onInboundMessage!(_inbound(text: 'hi', chatId: 'wxid_a'));
      await bridge.onInboundMessage!(_inbound(text: 'hi', chatId: 'wxid_b'));

      expect(capturedSessionIds, hasLength(2));
      expect(
        capturedSessionIds.toSet().length,
        2,
        reason: 'different chatId must resolve to different sessionIds',
      );
    });
  });

  group('AssistantCoordinator 远程 fail-closed（P0-A.1 任务 1）', () {
    // 内存授权 store —— 不触达 app_settings / DB，纯 Dart。
    final store = _MemoryAuthStore();
    final auth = RemoteAuthorizationService(store);

    setUp(() {
      store.clear();
    });

    AssistantCoordinator buildCoordinator({
      RemoteAuthorizationGateway? gateway,
    }) {
      return AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called: clientFactory');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
        // 远程模式（默认 localMode=false）：缺授权 → fail-closed 拒绝。
        authorization: gateway,
      );
    }

    test('远程模式缺失授权对象 → 强制拒绝，不回话、不触达 clientFactory', () async {
      coordinator = buildCoordinator(); // 不传 authorization
      coordinator.start();

      await bridge.onInboundMessage!(_inbound(text: '列出小说'));

      // 缺授权 → 拒绝：不开始处理（无 processing lifecycle）、无模型解析，
      // 只发一条"安全配置不完整"提示。
      expect(bridge.processingStartCalls, isEmpty);
      expect(bridge.processingEndCalls, isEmpty);
      expect(bridge.sentMessages, hasLength(1));
      expect(bridge.sentMessages.last.$1, _testChatId);
      expect(bridge.sentMessages.last.$2, contains('安全配置不完整'));
    });

    test('远程模式授权判定为 false → 拒绝并回"尚未授权"提示', () async {
      // 未授权（无记录）：isMessageAuthorized 返回 false。
      coordinator = buildCoordinator(gateway: auth);
      coordinator.start();

      await bridge.onInboundMessage!(_inbound(text: '列出小说'));

      expect(bridge.processingStartCalls, isEmpty);
      expect(bridge.sentMessages, hasLength(1));
      expect(bridge.sentMessages.last.$2, contains('尚未被授权'));
      // 拒绝应落审计
      expect(auth.auditEvents.any((e) => e.event == 'deny_message'), isTrue);
    });

    test('远程模式授权有效（write scope）→ 放行进入 turn 处理流程', () async {
      // 会话级授权（userId 为 null）：与入站消息缺省 userId（null）匹配，
      // 微信私聊消息身份可验证，显式声明 allowSessionWide。
      // 用户级授权（userId=wxid_alice）不会匹配缺省 userId 的消息，
      // 见下一用例「授权绑定 userId，缺失身份声明的消息不匹配」。
      await auth.authorizeRemoteUser(
        channelType: _testChannelType,
        chatId: _testChatId,
        userId: null,
        scope: RemotePermissionScope.write,
        allowSessionWide: true,
      );
      coordinator = buildCoordinator(gateway: auth);
      coordinator.start();

      // 放行后进入 _processTurn：本测试无模型配置 → 走"尚未配置"兜底。
      await bridge.onInboundMessage!(_inbound(text: '列出小说'));

      expect(bridge.processingStartCalls, [_testChatId]);
      expect(bridge.sentMessages, hasLength(1));
      expect(bridge.sentMessages.last.$2, contains('尚未配置默认聊天模型'));
    });

    test('授权绑定 userId，缺失身份声明的消息不匹配', () async {
      await auth.authorizeRemoteUser(
        channelType: _testChannelType,
        chatId: _testChatId,
        userId: 'wxid_specific_user',
        scope: RemotePermissionScope.write,
      );
      coordinator = buildCoordinator(gateway: auth);
      coordinator.start();

      // 消息 address 无 userId（InboundMessage.address.userId 为 null）→ 不匹配
      await bridge.onInboundMessage!(_inbound(text: '列出小说'));

      expect(bridge.sentMessages, hasLength(1));
      expect(bridge.sentMessages.last.$2, contains('尚未被授权'));
    });
  });
}

/// 内存授权存储 —— 与 remote_authorization_service_test 同构，纯 Dart。
class _MemoryAuthStore extends RemoteAuthorizationStore {
  final Map<String, String> _data = {};

  void clear() => _data.clear();

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }
}
