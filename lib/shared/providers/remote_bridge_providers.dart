// 职责: 组装微信桥接、跨作品助手与后台写作消息转发。
//       并自动挂载 AssistantCoordinator 把入站消息接入 AI turn runner；
//       提供 start_job / job_status / send_to_job / create_novel / edit_novel /
// 关联文件:
//   lib/shared/services/remote/remote_bridge_service.dart
//   lib/shared/services/remote/run_output_forwarder.dart
//   lib/shared/services/ai/assistant/coordinator.dart
//   lib/shared/services/ai/headless_session_turn.dart
//   lib/shared/database/daos/session_subscriptions_dao.dart
//   lib/shared/models/app_settings_aggregate_data.dart
//   lib/shared/providers/settings_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

import '../agent/message.dart';
import '../database/app_database.dart';
import '../database/remote_authorization_audit_store.dart';
import '../database/remote_authorization_store.dart';
import '../logger/app_logger.dart';
import '../models/ai_chat_models.dart';
import '../models/ai_provider.dart';
import '../models/app_settings_aggregate_data.dart';
import '../models/novel.dart';
import '../providers/ai_providers.dart';
import '../providers/novel_providers.dart';
import '../providers/prompt_template_provider.dart';
import '../providers/settings_providers.dart';
import '../providers/usage_query_providers.dart';
import '../services/ai/ai_http_client_lease.dart';
import '../services/ai/ai_service_config.dart';
import '../services/ai/assistant/coordinator.dart';
import '../services/ai/chat.dart';
import '../services/ai/headless_session_turn.dart';
import '../services/remote/notify_controls.dart';
import '../services/remote/remote_bridge_service.dart';
import '../services/remote/remote_authorization_service.dart';
import '../services/remote/run_output_forwarder.dart';
import '../services/remote/run_resource_verifier.dart';
import '../services/remote/wechat_api.dart';
import '../services/credentials/credential_cipher.dart';
import '../services/credentials/credential_json.dart';

final _log = AppLogger.forModule('RemoteBridge');

/// 凭证加密基础设施单例（P0-C）。
///
/// 生产默认 [CredentialCipher]；测试经 [debugSetCredentialCipher] 覆盖。
/// 微信凭证读写边界（[_readRemoteBridgeSettings] / [_updateWechatBridgeChannel]）
/// 使用本实例做敏感字段加解密。
CredentialCipher? _credentialCipherOverride;

CredentialCipher get _credentialCipher =>
    _credentialCipherOverride ??= CredentialCipher();

@visibleForTesting
void debugSetCredentialCipher(CredentialCipher? cipher) {
  _credentialCipherOverride = cipher;
}

/// Run 标题（来源标签）从 seed 派生的截断长度上限。
const _runTitleMaxChars = 30;

/// 远程 run seed 前缀指示（方案 §5.3 流程 4）。
///
/// 注入到 seed 文本头部，告知 Orchestrator 它在被远程观察：
/// - 关键节点调 Run notify progress（写入收件箱供 Assistant 汇总）
/// - 需要用户输入时调 Run notify question（即时推送到微信），提问后结束本轮等待回复
/// - 出错时调 Run notify error（即时推送到微信）
/// - 完成后调 Run notify complete
/// 仅 prompt 文本，配合 notifyCallback 实现 question/error 即时转发。
///
/// P0-B.3 任务3（受控通知）：Run notify 是受控能力——仅向当前 Job 绑定会话
/// 发送（不得指定任意目标用户/渠道）；单条内容不超过
/// [notifyMaxContentLength] 字符；60 秒窗口内不超过 [notifyMaxPerWindow] 条；
/// 敏感凭证（token/api key/secret 等）自动脱敏。进度/完成写收件箱（Assistant
/// 下一轮汇总），提问/错误即时推送微信。
const _remoteRunSeedPrefix =
    '【远程观察模式】'
    '你正在被远程观察（用户通过微信，看不到你的中间思考与正文产出）。'
    '关键节点用 Run notify progress 上报进度（写入收件箱供 Assistant 汇总）；'
    '需要用户输入时用 Run notify question 提问（会即时推送到微信），提问后结束本轮等待回复；'
    '出错时用 Run notify error（会即时推送到微信）；'
    '完成后用 Run notify complete。'
    '注意：notify 只能发往当前会话（不要指定目标用户/渠道），'
    '单条不超过 $notifyMaxContentLength 字符，'
    '60 秒内不超过 $notifyMaxPerWindow 条，敏感凭证会自动脱敏。\n\n'
    '任务种子：\n';

/// 读取远程桥接持久化快照（所有渠道的开关 + 凭证 + context_token，同一个
/// app_settings key）。
///
/// 键缺失或 JSON 损坏都回落到 [RemoteBridgeSettingsData.defaults]（开关默认开、未登录）：
/// 损坏时最坏结果是让用户重扫一次码，不值得因此中断启动。
Future<RemoteBridgeSettingsData> _readRemoteBridgeSettings(
  AppDatabase appDb,
) async {
  final raw = await appDb.appSettingsDao.get(
    RemoteBridgeSettingsData.appSettingsKey,
  );
  if (raw == null || raw.isEmpty) {
    return RemoteBridgeSettingsData.defaults;
  }
  try {
    // P0-C：敏感字段密文 → 明文后解析；旧明文原样兼容。
    // 解密失败（密钥不可用/篡改）抛异常 → 落入 catch 回落 defaults
    // （凭证视为未登录，fail-closed，不降级明文）。
    final decrypted = await decryptWechatAggregate(raw, _credentialCipher);
    return RemoteBridgeSettingsData.decode(decrypted);
  } catch (error, stackTrace) {
    _log.error(
      '[DB] table=app_settings operation=SELECT '
      'id=${RemoteBridgeSettingsData.appSettingsKey} malformed aggregate',
      error: error,
      stackTrace: stackTrace,
    );
    return RemoteBridgeSettingsData.defaults;
  }
}

/// 远程桥接持久化写入的串行链。
///
/// 开关、登录确认、-14 清凭证、上下文 token 四条路径都读-改-写同一个 key，
/// 并发交错会丢更新（例如关开关时一条在途的 token 写回把 enabled 改回开启，
/// 下次启动桥接无视用户意图自动运行）。模式同 novel_workspace_state_provider
/// 的 _writeChain。
Future<void> _remoteBridgeWriteChain = Future<void>.value();

/// 读-改-写微信渠道条目。开关与三个凭证回调都改同一个 key，必须先读回其余字段，
/// 否则会互相覆盖（例如持久化上下文 token 时把 credentials 抹掉），
/// 也会连带抹掉其它渠道的条目。所有写入经 [_remoteBridgeWriteChain] 串行执行。
///
/// 失败经返回的 Future 传播给调用方记 [DB] 日志；链自身吞掉错误，
/// 单次失败不阻塞后续排队写入。
Future<void> _updateWechatBridgeChannel(
  AppDatabase appDb,
  RemoteBridgeWechatData Function(RemoteBridgeWechatData current) update,
) {
  final task = _remoteBridgeWriteChain.then((_) async {
    final current = await _readRemoteBridgeSettings(appDb);
    // P0-C：写前加密敏感字段（幂等——已加密跳过；加密失败抛异常 → 写失败）。
    final value = await encryptWechatAggregate(
      current.copyWith(wechat: update(current.wechat)).encode(),
      _credentialCipher,
    );
    await appDb.appSettingsDao.set(
      key: RemoteBridgeSettingsData.appSettingsKey,
      value: value,
    );
  });
  _remoteBridgeWriteChain = task.catchError((_) {});
  return task;
}

/// adapter 凭证 → 持久化形态。
RemoteBridgeWechatCredentialsData _toCredentialsData(
  WechatCredentials credentials,
) => RemoteBridgeWechatCredentialsData(
  token: credentials.token,
  baseUrl: credentials.baseUrl,
  accountId: credentials.accountId,
  userId: credentials.userId,
);

/// 持久化形态 → adapter 凭证。
WechatCredentials _toWechatCredentials(
  RemoteBridgeWechatCredentialsData data,
) => WechatCredentials(
  token: data.token,
  baseUrl: data.baseUrl,
  accountId: data.accountId,
  userId: data.userId,
);

/// adapter 的 chatId → token 运行时映射 → 持久化条目列表。
List<RemoteBridgeWechatChatContextData> _toChatContexts(
  Map<String, String> contextTokens,
) => <RemoteBridgeWechatChatContextData>[
  for (final entry in contextTokens.entries)
    RemoteBridgeWechatChatContextData(
      chatId: entry.key,
      contextToken: entry.value,
    ),
];

/// 持久化条目列表 → adapter 的 chatId → token 运行时映射。
Map<String, String> _toContextTokens(
  List<RemoteBridgeWechatChatContextData> chatContexts,
) => <String, String>{
  for (final context in chatContexts) context.chatId: context.contextToken,
};

/// 持久化微信桥接开关。供设置页开关调用 —— 与凭证同 key，走同一条读-改-写。
final remoteBridgeEnabledWriterProvider =
    Provider<Future<void> Function(bool enabled)>((ref) {
      final appDb = ref.watch(appDatabaseProvider);
      return (enabled) async {
        try {
          await _updateWechatBridgeChannel(
            appDb,
            (current) => current.copyWith(enabled: enabled),
          );
          _log.info('[Persist] wechat bridge enabled=$enabled');
        } catch (error, stackTrace) {
          _log.error(
            '[DB] wechat bridge enabled persist failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      };
    });

/// 运行时安全门禁：本地用户显式确认启用远程桥接（P0-A）。
///
/// 旧版本持久化的 `enabled: true` 缺少确认标记，不能自动启动消费循环。
/// 本 provider 只在本地可信设置界面由用户操作时调用，把 `remoteConfirmed`
/// 置 true；与 [remoteBridgeEnabledWriterProvider] 一样走同一条读-改-写链，
/// 避免并发交错丢更新。
final remoteBridgeConfirmEnabledProvider =
    Provider<Future<void> Function()>((ref) {
      final appDb = ref.watch(appDatabaseProvider);
      return () async {
        try {
          await _updateWechatBridgeChannel(
            appDb,
            (current) => current.copyWith(
              enabled: true,
              remoteConfirmed: true,
            ),
          );
          _log.info('[Persist] wechat bridge remote confirmed (gate opened)');
        } catch (error, stackTrace) {
          _log.error(
            '[DB] wechat bridge remote confirmed persist failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      };
    });

/// 远程授权存储：落 remote_authorizations 独立表（Drift）。
///
/// P0-B B2 迁移后，授权记录从 app_settings 单 key JSON 迁入
/// remote_authorizations 表。本 store 读表返回授权记录数组、写表全量替换
/// （事务），首次读写时惰性导入旧 JSON（幂等、可恢复、失败保留原始 JSON
/// 并按 deny-by-default 兜底）。授权服务本体（纯 Dart）无需改动。
final remoteAuthorizationStoreProvider =
    Provider<RemoteAuthorizationStore>((ref) {
      final appDb = ref.watch(appDatabaseProvider);
      return DriftRemoteAuthorizationStore(appDb);
    });

/// 远程授权审计持久化存储（P0-B B3）：落 remote_authorization_audit 表。
///
/// 追加式事件记录；写入失败内部吞掉（不影响授权判定）；提供按时间 / 用户 /
/// 渠道 / Job 查询与保留期限清理。授权服务通过本 provider 注入。
final remoteAuthorizationAuditStoreProvider =
    Provider<RemoteAuthorizationAuditStore>((ref) {
      final appDb = ref.watch(appDatabaseProvider);
      return DriftRemoteAuthorizationAuditStore(appDb);
    });

/// 远程统一授权服务单例（P0-A A2）。
///
/// 语义：deny-by-default；授权必须从本地可信界面产生；绑定
/// (channelType, chatId, userId)；身份来自可信渠道适配器。coordinator 与
/// bridge 共用本实例，保证两层入口授权状态单一来源。
/// 远程统一授权服务单例（P0-A A2）。
///
/// 语义：deny-by-default；授权必须从本地可信界面产生；绑定
/// (channelType, chatId, userId)；身份来自可信渠道适配器。coordinator 与
/// bridge 共用本实例，保证两层入口授权状态单一来源。
///
/// P0-A.2 统一门禁：注入 [RemoteRuntimeStatus] 读取闭包。闭包内每次判定都
/// **重新读 app_settings**（不走缓存的 Riverpod provider）——确保用户关闭
/// 远程助手 / 撤销授权 / 降级后，下一次授权判定立即感知新状态并 fail-closed，
/// 已运行的 Job 在执行下一个敏感操作前即被中止。读取失败按 fail-closed。
final remoteAuthorizationServiceProvider =
    Provider<RemoteAuthorizationService>((ref) {
      final store = ref.watch(remoteAuthorizationStoreProvider);
      final auditStore = ref.watch(remoteAuthorizationAuditStoreProvider);
      final appDb = ref.watch(appDatabaseProvider);
      return RemoteAuthorizationService(
        store,
        auditStore: auditStore,
        runtimeStatusProvider: () async {
          try {
            final saved = await _readRemoteBridgeSettings(appDb);
            return RemoteRuntimeStatus(
              enabled: saved.wechat.enabled,
              remoteConfirmed: saved.wechat.remoteConfirmed,
            );
          } catch (error, stackTrace) {
            _log.error(
              '[RemoteBridge] runtime status read failed — fail-closed '
              'error=$error',
              error: error,
              stackTrace: stackTrace,
            );
            return const RemoteRuntimeStatus.failClosed();
          }
        },
        // P0-B.3 任务2：注入 DAO 支撑的作品域 Run 写操作目标资源归属校验器，
        // 使 Run 写操作第 4 维（作品归属）真实生效——可信作品 ID 须为 novels
        // 表中的真实作品，工具参数声明的目标作品 ID 与可信作品一致才放行，
        // 跨作品（作品 A 的 Job 读/改/删作品 B 资源）一律拒绝。
        resourceVerifier: _DriftRunResourceVerifier(appDb),
      );
    });

/// 远程桥接服务单例 provider。
///
/// 服务为有状态长生命周期（持有 adapter、登录订阅、消费循环），需 keepAlive。
/// 凭证与 context_token 经回调持久化到 app_settings 的
/// [RemoteBridgeSettingsData.appSettingsKey]，重启后由
/// [remoteBridgeAutoRestoreProvider] 自动恢复。
final remoteBridgeServiceProvider = Provider<RemoteBridgeService>((ref) {
  final appDb = ref.watch(appDatabaseProvider);
  // P0-A A2：注入统一授权服务，bridge 路由层做消息级纵深拦截。
  final authorization = ref.watch(remoteAuthorizationServiceProvider);
  final service = RemoteBridgeService(authorization: authorization);

  // 登录成功 → 持久化 credentials，并按用户开关启动 bridge。
  service.onLoginConfirmed = (credentials) async {
    var enabled = false;
    try {
      final saved = await _readRemoteBridgeSettings(appDb);
      // P0-A.1 任务 4：启动判定与重启恢复同源 —— enabled && remoteConfirmed。
      // 只读 enabled 会留下绕过点：历史 enabled=true 无确认标记时，新扫码仍会
      // 重启消费循环。必须与 remoteBridgeAutoRestoreProvider 一致，本地用户在
      // 设置界面显式确认（remoteConfirmed=true）后才允许启动。
      enabled = saved.wechat.enabled && saved.wechat.remoteConfirmed;
      await _updateWechatBridgeChannel(
        appDb,
        (current) =>
            current.copyWith(credentials: _toCredentialsData(credentials)),
      );
      _log.info('[Persist] credentials saved userId=${credentials.userId}');
    } catch (error, stackTrace) {
      _log.error(
        '[DB] credentials persist failed',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // 新扫码成功后也要进入与重启恢复相同的消费状态；否则 UI 虽显示已连接，
    // 但 bridge 实际未运行，入站消息无人消费。
    if (enabled && !service.isRunning) {
      try {
        await service.start();
      } catch (error, stackTrace) {
        _log.error(
          '[RemoteBridge] start after login failed userId=${credentials.userId}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  };

  // -14 session 过期或用户登出 → 清 credentials + 上下文 token，保留 enabled
  //（用户意图与掉线无关，重新扫码后应沿用原来的开关状态）。
  service.onCredentialsCleared = () async {
    try {
      await _updateWechatBridgeChannel(
        appDb,
        (current) => current.copyWith(
          credentials: null,
          chatContexts: const <RemoteBridgeWechatChatContextData>[],
        ),
      );
      _log.info('[Persist] credentials + chat contexts cleared');
    } catch (error, stackTrace) {
      _log.error(
        '[DB] credentials clear failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  };

  // 上下文 token 变更 → 全量写回。
  // 全量写：单 chat 维度增量写需额外读-改-写，且条目量级小（chat 数 ≤ 用户数）。
  service.onContextTokenChanged = (chatId, token) async {
    try {
      final chatContexts = _toChatContexts(service.contextTokens);
      await _updateWechatBridgeChannel(
        appDb,
        (saved) => saved.copyWith(chatContexts: chatContexts),
      );
      if (_log.isDebugEnabled) {
        _log.debug(
          '[Persist] chat contexts saved chatId=$chatId '
          'total=${chatContexts.length}',
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        '[DB] chat contexts persist failed chatId=$chatId',
        error: error,
        stackTrace: stackTrace,
      );
    }
  };

  ref.onDispose(service.dispose);
  return service;
});

/// Run 下行转发器单例 provider。
///
/// 非.autoDispose — forwarder 生命周期 = app 生命周期。订阅关系持久化于
/// `session_subscriptions` 表，跨重启后由 [remoteBridgeAutoRestoreProvider] 重新
/// [RunOutputForwarder.register]。
final runOutputForwarderProvider = Provider<RunOutputForwarder>((ref) {
  final bridge = ref.watch(remoteBridgeServiceProvider);
  final forwarder = RunOutputForwarder(ref: ref, bridge: bridge);
  ref.onDispose(forwarder.dispose);
  return forwarder;
});

/// app 启动时自动恢复远程桥接（免扫码 + forwarder 重挂）。
///
/// 流程（方案 §5.3 流程 1）：
/// 1. 读 app_settings 中该渠道的 enabled + credentials + context_tokens
/// 2. 凭证存在 → bridge.restoreAndStart（恢复消费循环）
/// 3. 凭证不存在 → 停在未登录态等用户扫码
/// 4. bridge 启动后 → 读 session_subscriptions 重挂 forwarder 订阅
///
/// 用户在设置页关掉该渠道开关时，仍恢复凭证让 UI 显示已连接，但不启动消费循环，
/// 也不重挂 forwarder / 不做孤儿 run 对账 —— 桥接是停的，这些动作要么无处可发，
/// 要么会把用户已关闭的通道重新唤醒。
///
/// 返回 true 表示恢复成功（bridge 已启动），false 表示无凭证、开关关闭或恢复失败。
///
/// 调用方应在 app 初始化完成后调 `ref.read(remoteBridgeAutoRestoreProvider)`。
final remoteBridgeAutoRestoreProvider = FutureProvider<bool>((ref) async {
  final appDb = ref.read(appDatabaseProvider);
  final bridge = ref.read(remoteBridgeServiceProvider);
  final forwarder = ref.read(runOutputForwarderProvider);

  // 1. 读微信渠道的持久化条目（开关 + 凭证 + 上下文 token 同一个 key）。
  // 凭证字段不全时 fromJsonOrNull 已判为 null，这里无需再解析、再兜错。
  final saved = await _readRemoteBridgeSettings(appDb);
  final channel = saved.wechat;
  // P0-A 运行时门禁：enabled 必须由本地用户显式确认（remoteConfirmed）才允许
  // 自动启动。旧版本持久化的 enabled=true 缺少确认标记 → 视为未启用，
  // 历史远程会话升级后必须重新由本地用户确认启用，不允许绕过新默认值。
  final enabled = channel.enabled && channel.remoteConfirmed;
  final credentials = channel.credentials;
  if (credentials == null) {
    _log.info('[Restore] no persisted credentials — staying logged out');
    return false;
  }

  // 2. 恢复（+ 按「开关 && 已确认」决定是否启动消费循环）
  final ok = await bridge.restoreAndStart(
    credentials: _toWechatCredentials(credentials),
    contextTokens: _toContextTokens(channel.chatContexts),
    autoStart: enabled,
  );
  if (!ok) {
    _log.warning('[Restore] restoreAndStart failed — user should re-scan QR');
    return false;
  }
  if (!enabled) {
    _log.info(
      '[Restore] credentials restored but bridge disabled by user setting',
    );
    return false;
  }

  // 3. 重挂 forwarder 订阅 — 读 session_subscriptions 中所有 remote_chat 订阅。
  try {
    final subs = await appDb.sessionSubscriptionsDao.listBySubscriberType(
      sessionSubscriberRemoteChat,
    );
    for (final sub in subs) {
      // A3: 整个 per-sub 恢复逻辑（getById + getOrCreateByChat + register）
      // 包裹在 try/catch 内，单条失败不中断其余订阅恢复。
      try {
        final session = await appDb.aiChatSessionDao.getById(sub.sessionId);
        final runTitle = session?.title ?? sub.sessionId;
        // 恢复时为每个 (channelType, chatId) 解析 Assistant 会话 id，
        // 供 forwarder 崩溃兜底写 inbox。getOrCreate：跨重启后无 Assistant 会话行
        // 时自动补建，与 startJob 路径行为一致。
        final assistantSession = await appDb.assistantSessionDao
            .getOrCreateByChat(
              channelType: sub.channelType!,
              chatId: sub.targetId,
            );
        await forwarder.register(
          sessionId: sub.sessionId,
          runTitle: runTitle,
          chatId: sub.targetId,
          channelType: sub.channelType!,
          assistantSessionId: assistantSession.id,
        );

        // A6: 重启孤儿 run 兜底 —— 该 session 无 in-flight run（重启后必然），
        // 写一条 run_observer/error inbox + 转发 IM，一次性对账（不引入轮询）。
        // 注意：重启后所有订阅均不 in-flight，包括已正常完成的 run —— 属可接受边界，
        // Assistant 与用户可据上下文判断是否需要续跑。
        final isRunning = ref
            .read(aiChatRuntimeProvider(sub.sessionId))
            .isRequestInFlight;
        if (!isRunning) {
          const orphanText = 'Run 因应用重启中断';
          try {
            await appDb.assistantInboxDao.append(
              assistantSessionId: assistantSession.id,
              source: 'run_observer',
              messageType: 'error',
              content: orphanText,
              sourceRef: sub.sessionId,
            );
          } catch (error, stackTrace) {
            _log.error(
              '[Restore] orphan run inbox write failed '
              'session=${sub.sessionId} '
              'assistantSession=${assistantSession.id}',
              error: error,
              stackTrace: stackTrace,
            );
          }
          final ok = await bridge.sendToUser(
            sub.targetId,
            '【$runTitle】$orphanText',
          );
          if (!ok) {
            _log.warning(
              '[Restore] orphan run IM forward failed '
              'chatId=${sub.targetId} session=${sub.sessionId}',
            );
          }
        }
      } catch (error, stackTrace) {
        _log.error(
          '[Restore] per-sub restore failed session=${sub.sessionId}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _log.info('[Restore] forwarder re-registered ${subs.length} subscriptions');
  } catch (error, stackTrace) {
    _log.error(
      '[Restore] session_subscriptions query failed',
      error: error,
      stackTrace: stackTrace,
    );
  }

  return true;
});

/// 从 seed 派生 run 标题（来源标签 `【run 标题】`）。截断到 [_runTitleMaxChars]。
String _runTitleFromSeed(String seed) {
  final trimmed = seed.trim();
  if (trimmed.length <= _runTitleMaxChars) return trimmed;
  return '${trimmed.substring(0, _runTitleMaxChars)}…';
}

/// 校验 runSessionId 是否归属该 chatId（session_subscriptions.target_id == chatId）。
///
/// 用于 job_status / send_to_job 的前置归属校验，防跨 chat 越权。
Future<bool> _isRunOwnedByChat(
  AppDatabase appDb,
  String runId,
  String chatId,
) async {
  final subs = await appDb.sessionSubscriptionsDao.listBySession(runId);
  return subs.any(
    (s) =>
        s.subscriberType == sessionSubscriberRemoteChat && s.targetId == chatId,
  );
}

/// P0-B.3 任务2：DAO 支撑的作品域 Run 写操作目标资源归属校验器。
///
/// 在 [DefaultRunResourceVerifier] 的「显式目标作品 ID == 可信作品 ID」比对之上，
/// 叠加 DAO 级校验：可信作品 ID 必须真实存在于 `novels` 表（拒绝伪造/失效的
/// workId），显式声明的目标作品 ID 也必须真实存在——归属不一致/不存在一律
/// 拒绝（deny-by-default）。stagings/editing 为非 DB 资源（经
/// `SessionFiles(novelId: workId)` 关联作品，天然绑定可信作品），其归属由
/// 可信作品 ID 的 DAO 存在性校验保证。
class _DriftRunResourceVerifier implements RunResourceVerifier {
  _DriftRunResourceVerifier(this._appDb);

  final AppDatabase _appDb;

  @override
  Future<bool> verifyWorkResource({
    required String? workId,
    required String command,
    required String subcommand,
    Map<String, dynamic>? toolArguments,
  }) async {
    // 1) 可信作品必须真实存在（DAO 归属一致）；不存在/缺失 → 拒绝（伪造/失效）。
    //    作品域写操作在策略第 4 维已保证 workId 非空；读操作可能为 null。
    if (workId == null || workId.isEmpty) {
      return false;
    }
    try {
      final trustedNovel = await _appDb.novelDao.get(workId);
      if (trustedNovel == null) {
        return false;
      }
    } catch (_) {
      // DAO 读取失败 → 归属不可证 → 拒绝（安全侧）。
      return false;
    }
    // 2) 显式目标作品 ID 比对（跨作品拒绝）+ 目标作品存在性。
    final target = extractTargetWorkId(toolArguments);
    if (target != null) {
      if (target != workId) {
        return false;
      }
      try {
        final targetNovel = await _appDb.novelDao.get(target);
        if (targetNovel == null) {
          return false;
        }
      } catch (_) {
        return false;
      }
    }
    return true;
  }
}

/// P0-A 正式验收 V1.1 / P0-B B0：后台 Job 授权复核 gate 的统一判定。
///
/// [jobToolName] 为 Job 运行权对应的远程工具（`start_job` / `send_to_job`）；
/// [toolName] 为即将执行的具体工具名；[toolArguments] 为工具参数（用于
/// `Run` 子命令级授权解析）；[workId] 为当前 Job 绑定的作品（P0-B.2：Run
/// 写操作必须绑定明确作品，见 [RemotePermissionPolicy] 第 4 维）。判定规则见
/// [RemoteAuthorizationService.isJobToolAuthorized]（携带工具名的逐工具
/// 复核、`Run` 子命令级授权、[RemoteAuthorizationService.jobOrchestrationCapabilities]
/// 白名单内编排能力回退 Job 级复核、其余非批准工具 fail-closed 拒绝）。
Future<bool> _jobGateAuthorize(
  RemoteAuthorizationService authorization, {
  required String channelType,
  required String chatId,
  String? userId,
  required String jobToolName,
  String? toolName,
  Map<String, dynamic>? toolArguments,
  String? jobId,
  String? workId,
}) {
  return authorization.isJobToolAuthorized(
    jobToolName,
    toolName: toolName,
    toolArguments: toolArguments,
    channelType: channelType,
    chatId: chatId,
    userId: userId,
    jobId: jobId,
    workId: workId,
  );
}

/// 取最近 1-2 条 assistant 非流式消息的 text block 原文（不做 LLM 摘要，Rule 5）。
List<String> _recentAssistantTexts(List<AiMessage> messages) {
  final result = <String>[];
  for (final msg in messages.reversed) {
    if (msg.role != AiMessageRole.assistant || msg.isStreaming) continue;
    final text = msg.effectiveText.trim();
    if (text.isEmpty) continue;
    result.insert(0, text);
    if (result.length >= 2) break;
  }
  return result;
}

/// 为 Assistant 的 `list_novels` 工具提供书架可见作品。
final assistantNovelListCallbackProvider =
    Provider<Future<List<Map<String, dynamic>>> Function()>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return () async {
        try {
          final novels = await database.novelDao.watchAll().first;
          return novels.shelfVisible
              .map(
                (novel) => <String, dynamic>{
                  'id': novel.id,
                  'title': novel.title,
                  'status': novel.status,
                  'word_count': novel.wordCount,
                  'updated_at': novel.updatedAt.toIso8601String(),
                },
              )
              .toList(growable: false);
        } catch (error) {
          throw StateError('listNovels failed: $error');
        }
      };
    });

/// Assistant 协调器单例 provider。
///
/// 把 [RemoteBridgeService.onInboundMessage] 接到 [AssistantTurnRunner]。
/// 启动时机：bridge 自身的 start() 被调用之前或之后均可（handler 是被动回调）。
/// 依赖 [remoteBridgeServiceProvider]，因此本 provider 被 read 时会自动实例化 bridge。
final assistantCoordinatorProvider = Provider<AssistantCoordinator>((ref) {
  final bridge = ref.watch(remoteBridgeServiceProvider);
  final appDb = ref.watch(appDatabaseProvider);
  // P0-A A2/A3：与 bridge 路由层共用同一授权实例（A1 单点 + A2 纵深同源）。
  final authorization = ref.watch(remoteAuthorizationServiceProvider);
  final promptService = ref.watch(aiPromptServiceProvider);
  final usageService = ref.watch(usageServiceProvider);
  final listNovels = ref.watch(assistantNovelListCallbackProvider);
  final httpClientLeasePool = AiHttpClientLeasePool(
    ref.read(aiHttpClientRegistryProvider),
  );
  ref.onDispose(httpClientLeasePool.dispose);

  // 用闭包封装 ref.read，避免把 ProviderContainer 传给 coordinator。
  // 这样 coordinator 和 turn runner 都是纯 Dart 类，不耦合 Riverpod。
  Future<AiClient> clientFactory({
    required String providerId,
    required String model,
    required String sessionId,
  }) async {
    final config = ref.read(
      currentAiConfigProvider(providerId: providerId, model: model),
    );
    if (config == null || !config.isValid) {
      throw StateError(
        'AI config invalid for provider=$providerId model=$model',
      );
    }
    final httpClient = httpClientLeasePool.clientFor(config);
    final service = AiClient.fromConfig(
      AiServiceConfig(
        provider: config,
        chatModel: model,
        sourceSessionId: sessionId,
      ),
      httpClient: httpClient,
      traceHeadersProvider: () => {
        'x-session-id': sessionId,
        'x-session-parent-id': sessionId,
      },
    );
    await service.initialize();
    return service;
  }

  void onUsageChanged() {
    ref.invalidate(todayUsageProvider);
    ref.invalidate(thisMonthUsageProvider);
  }

  // create_novel / edit_novel 走 NovelActionsService 落地，与小说库其他入口一致。
  Future<Map<String, dynamic>> createNovel(Map<String, dynamic> novel) async {
    try {
      final actions = ref.read(novelActionsProvider);
      final novelId = await actions.createNovel(
        title: novel['title'] as String? ?? '',
        description: novel['description'] as String? ?? '',
        authorName:
            novel['author_name'] as String? ?? novel['authorName'] as String?,
        category: novel['category'] as String? ?? '',
        type: novel['type'] as String?,
        tags: (novel['tags'] as List?)?.map((e) => e.toString()).toList(),
      );
      return {'ok': true, 'novel_id': novelId};
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteBridge] createNovel failed error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return {'ok': false, 'error': error.toString()};
    }
  }

  Future<Map<String, dynamic>> editNovel(
    String novelId,
    Map<String, dynamic> fields,
  ) async {
    try {
      final db = ref.read(appDatabaseProvider);
      final novel = await db.novelDao.get(novelId);
      if (novel == null) {
        return {'ok': false, 'error': 'novel not found: $novelId'};
      }
      final actions = ref.read(novelActionsProvider);
      await actions.updateNovel(
        novel: novel,
        title: fields['title'] as String? ?? novel.title,
        description: fields['description'] as String? ?? novel.description,
        authorName:
            fields['author_name'] as String? ??
            fields['authorName'] as String? ??
            novel.authorName,
        category: fields['category'] as String? ?? novel.category,
        type: fields['type'] as String? ?? novel.type,
        tags:
            (fields['tags'] as List?)?.map((e) => e.toString()).toList() ??
            novel.tags,
        removeCover: false,
      );
      return {'ok': true, 'novel_id': novelId};
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteBridge] editNovel failed novelId=$novelId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return {'ok': false, 'error': error.toString()};
    }
  }

  Future<Map<String, dynamic>> listChapters(String novelId) async {
    try {
      final db = ref.read(appDatabaseProvider);
      final novel = await db.novelDao.get(novelId);
      if (novel == null) {
        return {'ok': false, 'error': 'novel not found: $novelId'};
      }
      final path = novel.contentDatabasePath;
      if (path == null || path.isEmpty) {
        return {'ok': false, 'error': 'novel content database is unavailable'};
      }
      final chapters = await ref
          .read(novelContentServiceProvider(path))
          .getChapters();
      return {
        'ok': true,
        'novel_id': novel.id,
        'title': novel.title,
        'chapters': [
          for (final chapter in chapters)
            if (chapter.isChapter)
              <String, dynamic>{
                'id': chapter.id,
                'chapter_num': chapter.chapterNum,
                'title': chapter.numberedTitle,
                'word_count': chapter.wordCount,
                'updated_at': chapter.updatedAt.toIso8601String(),
              },
        ],
      };
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteBridge] listChapters failed novelId=$novelId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return {'ok': false, 'error': 'failed to load chapter list'};
    }
  }

  final coordinator = AssistantCoordinator(
    bridge: bridge,
    dao: appDb.assistantSessionDao,
    inboxDao: appDb.assistantInboxDao,
    aiPromptService: promptService,
    usageService: usageService,
    clientFactory: clientFactory,
    readAiSettings: () => ref.read(aiSettingsProvider),
    // P0-A A3：与 bridge 路由层共用同一授权实例（A1 单点 + A2 纵深同源）。
    authorization: authorization,
    listNovels: listNovels,
    startJob: (
      novelId,
      seed, {
      required chatId,
      required channelType,
      userId,
    }) async {
      // ref.container = root ProviderContainer，供 startHeadlessRun 内部
      // 调 runHeadlessSessionTurn / ChatTurnRunner（二者签名要求 ProviderContainer）。
      final container = ref.container;
      final runTitle = _runTitleFromSeed(seed);
      // P0-A.1 任务 2：后台 Job 授权复核 gate —— 绑定当前渠道身份。
      // startHeadlessRun 内每个后台 turn 执行前复核「该身份仍持有 write 权」，
      // 授权被撤销/降级后，已运行 Job 的下一次敏感操作即被拒绝（fail-closed）。
      // P0-A 正式验收 V1.1/V1.2 + P0-B B0：gate 携带具体工具名 [toolName] 与
      // 工具参数 [toolArguments]。
      // - toolName 为 null（turn 入口复核）→ 按 Job 运行权（start_job）判定；
      // - toolName 为已批准远程工具 → 按该工具名逐工具复核（含未知工具拒绝）；
      // - toolName 为编排能力白名单（Run）→ 子命令级授权：敏感子命令
      //   （mcp.call / files.remove）fail-closed 拒绝，其余沿 Job 运行权；
      // - 其余工具名（SpawnAgent/Create/Write/Edit/MCP/Plugin 等）→ fail-closed
      //   拒绝——P0-A V1.2：未经明确允许的工具不得仅凭 Job 写入权限执行。
      Future<bool> jobAuthGate(
        String? toolName,
        Map<String, dynamic>? toolArguments,
      ) => _jobGateAuthorize(
        authorization,
        channelType: channelType,
        chatId: chatId,
        userId: userId,
        jobToolName: 'start_job',
        toolName: toolName,
        toolArguments: toolArguments,
        // P0-B.2：绑定当前启动 Job 的作品，使 Run 写操作第 4 维（作品归属）
        // 真实生效——start_job 的 novelId 即本 Job 的唯一作品。
        workId: novelId,
      );
      // 注入远程观察指示（仅 prompt 文本，让 Orchestrator 调 Run notify 上报进度/提问）。
      final seededText = '$_remoteRunSeedPrefix$seed';
      // 解析 Assistant 会话（run agent 的 notify 写入该会话的 inbox）。
      final assistantSession = await appDb.assistantSessionDao
          .getOrCreateByChat(channelType: channelType, chatId: chatId);
      final assistantSessionId = assistantSession.id;
      // notify 回调：run agent 调 `Run notify` 时写入 assistant_inbox，
      // 给 Assistant 下一轮 turn 组装 context 时注入。
      // question/error 额外即时 bridge.sendToUser 推微信，让 run 进行中用户不再全程静默；
      // progress/complete 仅写 inbox，由 Assistant 下一轮汇总，避免刷屏。
      // P0-B.3 任务3：受控通知——仅向当前 Job 绑定会话发送；长度截断；
      // 敏感信息脱敏；窗口内频率上限（超限丢弃，不阻塞 run）。
      final notifyTimes = <DateTime>[];
      Future<Map<String, dynamic>> notifyCallback(
        Map<String, dynamic> command,
      ) async {
        final action = command['action']?.toString() ?? 'progress';
        final rawContent = command['content']?.toString() ?? '';
        final sourceRef = command['source_ref']?.toString();
        // 受控约束：敏感信息脱敏 + 长度截断（防御性兜底，鉴权侧已拒超长）。
        final content = truncateNotifyContent(
          redactNotifyContent(rawContent),
          notifyMaxContentLength,
        );
        // 受控约束：频率上限（窗口内超限丢弃，防止刷屏/滥用）。
        final now = DateTime.now();
        if (!notifyFrequencyAllowed(notifyTimes, now)) {
          _log.warning(
            '[RemoteBridge] notify rate limited action=$action '
            'session=$assistantSessionId',
          );
          return {
            'ok': false,
            'error': 'notify rate limited (window=$notifyWindowDuration '
                'max=$notifyMaxPerWindow)',
          };
        }
        notifyTimes.add(now);
        try {
          await appDb.assistantInboxDao.append(
            assistantSessionId: assistantSessionId,
            source: 'run_agent',
            messageType: action,
            content: content,
            sourceRef: sourceRef,
          );
        } catch (error, stackTrace) {
          _log.error(
            '[RemoteBridge] notify inbox write failed '
            'assistantSession=$assistantSessionId action=$action error=$error',
            error: error,
            stackTrace: stackTrace,
          );
          return {'ok': false, 'error': '$error'};
        }
        // question/error 即时推送到微信（run 进行中用户不再全程静默）。
        // 用与 RunOutputForwarder 一致的【run 标题】前缀，让用户区分多个并行 run。
        if (action == 'question' || action == 'error') {
          final labeled = '【$runTitle】$content';
          final ok = await bridge.sendToUser(chatId, labeled);
          if (!ok) {
            _log.warning(
              '[RemoteBridge] notify forward failed chatId=$chatId '
              'action=$action chars=${labeled.length}',
            );
          }
        }
        return {'ok': true};
      }

      final result = await startHeadlessRun(
        container,
        novelId: novelId,
        seed: seededText,
        title: runTitle,
        notifyCallback: notifyCallback,
        authorizationGate: jobAuthGate,
      );
      switch (result.outcome) {
        case HeadlessRunOutcome.started:
          final sessionId = result.sessionId!;
          // 写订阅行：remote_chat → chatId（兼作 Assistant↔run 归属关联）。
          // try-catch：run 已启动，订阅行写入失败不回滚 run，仅记日志（转发不会生效）。
          try {
            await appDb.sessionSubscriptionsDao.add(
              sessionId: sessionId,
              subscriberType: sessionSubscriberRemoteChat,
              targetId: chatId,
              channelType: channelType,
            );
          } catch (error, stackTrace) {
            _log.error(
              '[RemoteBridge] startJob subscription write failed '
              'session=$sessionId chatId=$chatId',
              error: error,
              stackTrace: stackTrace,
            );
          }
          // 注册 forwarder — 即使订阅行写入失败也尝试注册内存监听
          // （内存监听不依赖 DB 行，转发靠内存订阅即可工作到 app 重启）。
          // assistantSessionId 已在 startJob 顶部解析，崩溃兜底时写其 inbox。
          try {
            await ref
                .read(runOutputForwarderProvider)
                .register(
                  sessionId: sessionId,
                  runTitle: runTitle,
                  chatId: chatId,
                  channelType: channelType,
                  assistantSessionId: assistantSessionId,
                );
          } catch (error, stackTrace) {
            _log.error(
              '[RemoteBridge] startJob forwarder register failed '
              'session=$sessionId chatId=$chatId',
              error: error,
              stackTrace: stackTrace,
            );
          }
          return {
            'ok': true,
            'status': 'started',
            'job_id': sessionId,
            'job_title': runTitle,
          };
        case HeadlessRunOutcome.alreadyRunning:
          // 调用方 Assistant 据此区分「已启动」与「已在跑」，避免误报。
          return {'ok': true, 'status': 'already_running'};
        case HeadlessRunOutcome.novelUnavailable:
          return {
            'ok': false,
            'error': 'novel or its content database is unavailable',
          };
        case HeadlessRunOutcome.noValidModel:
          return {
            'ok': false,
            'error': 'no valid chat model configured for this novel',
          };
        case HeadlessRunOutcome.failed:
          return {'ok': false, 'error': result.error ?? 'start_job failed'};
      }
    },
    jobStatus: (jobId, {required chatId, required channelType}) async {
      // 归属校验：防跨 chat 越权查询其他会话的 Job 状态。
      if (!await _isRunOwnedByChat(appDb, jobId, chatId)) {
        return {
          'ok': false,
          'error': 'job not found or not owned by this chat',
        };
      }
      final container = ref.container;
      final runtime = container.read(aiChatRuntimeProvider(jobId));
      final session = container.read(aiChatSessionProvider(jobId));
      final isRunning = runtime.isRequestInFlight;

      // 若 session 未在内存（app 重启后 forwarder 未重挂），recent_output 为空。
      // forwarder 已注册时 session 因 listen 保活，messages 在场。
      final recent = session.isLoaded
          ? _recentAssistantTexts(session.messages)
          : const <String>[];

      return {
        'ok': true,
        'state': isRunning ? 'running' : 'idle',
        'title': session.title,
        'message_count': session.messages.length,
        'recent_output': recent,
      };
    },
    sendToJob: (
      jobId,
      text, {
      required chatId,
      required channelType,
      userId,
    }) async {
      // P0-A.1 任务 2：后台续跑授权复核 gate —— 绑定当前渠道身份。
      // runHeadlessSessionTurn 在每个续跑 turn 执行前复核「该身份仍持有
      // write 权」，授权被撤销/降级后，Job 的续跑不再消耗模型请求（fail-closed）。
      // P0-A 正式验收 V1.1 / P0-B B0：gate 携带具体工具名与参数
      // （见 jobAuthGate 注释）。
      Future<bool> resumeAuthGate(
        String? toolName,
        Map<String, dynamic>? toolArguments,
      ) async {
        // P0-B.2：续跑 Job 绑定作品 = 该 ai_chat_session 的 novelId；解析失败
        // 时 workId 为 null → Run 写操作按「未绑定作品」fail-closed 拒绝
        // （策略第 4 维），杜绝续跑路径绕过作品归属校验。
        String? workId;
        try {
          final sessionRow = await appDb.aiChatSessionDao.getById(jobId);
          workId = sessionRow?.novelId;
        } catch (error, stackTrace) {
          _log.error(
            '[RemoteBridge] resumeAuthGate session novelId resolve failed '
            'jobId=$jobId — fail-closed (workId null)',
            error: error,
            stackTrace: stackTrace,
          );
          workId = null;
        }
        return _jobGateAuthorize(
          authorization,
          channelType: channelType,
          chatId: chatId,
          userId: userId,
          jobToolName: 'send_to_job',
          toolName: toolName,
          toolArguments: toolArguments,
          jobId: jobId,
          workId: workId,
        );
      }
      // 归属校验：防跨 chat 越权向其他会话的 Job 注入消息。
      if (!await _isRunOwnedByChat(appDb, jobId, chatId)) {
        return {
          'ok': false,
          'error': 'job not found or not owned by this chat',
        };
      }
      final container = ref.container;
      final isRunning = container
          .read(aiChatRuntimeProvider(jobId))
          .isRequestInFlight;

      if (isRunning) {
        final agent = container
            .read(aiChatRuntimeProvider(jobId).notifier)
            .agent;
        if (agent != null) {
          // a. steer — 注入 agent steering 队列，下一个 LLM round 前 drain 生效。
          agent.steer(
            AgentMessage.user(
              id: 'steer_${DateTime.now().millisecondsSinceEpoch}',
              content: text,
            ),
          );
          // 同时 addUserMessage 进 session transcript（transcript 完整性）。
          // turn 结束时由 headless turn 的 _persistHeadlessCompletedMessages 落库。
          container
              .read(aiChatSessionProvider(jobId).notifier)
              .addUserMessage(text);
          _log.info(
            '[RemoteBridge] sendToJob steered jobId=$jobId chatId=$chatId',
          );
          return {'ok': true, 'status': 'steered'};
        }
        // runtime 说在跑但 agent 为 null — 状态不一致，回退到 idle 续跑路径。
        _log.warning(
          '[RemoteBridge] sendToJob: isRequestInFlight but agent is null, '
          'falling back to idle resume jobId=$jobId',
        );
      }

      // b. idle — 续跑：用户消息作为新 turn 的 seed。
      // 需从 DB 查 session 的 novelId + novel 的 databasePath。
      final sessionRow = await appDb.aiChatSessionDao.getById(jobId);
      if (sessionRow == null) {
        return {'ok': false, 'error': 'job session not found in database'};
      }
      final novelId = sessionRow.novelId;
      final novel = await appDb.novelDao.get(novelId);
      final databasePath = novel?.contentDatabasePath;
      if (novel == null || databasePath == null || databasePath.isEmpty) {
        return {
          'ok': false,
          'error': 'novel or content database unavailable for this job',
        };
      }

      // 后台续跑（不 await — 工具立即返回，Job 在后台继续）。
      // runHeadlessSessionTurn 自持 keepAlive + startRequest/markRequestIdle，
      // seed 落库 + ensureHeadlessSessionLoaded 均在内部完成。
      unawaited(
        runHeadlessSessionTurn(
          container,
          sessionId: jobId,
          databasePath: databasePath,
          novel: novel,
          seed: text,
          authorizationGate: resumeAuthGate,
        ).then((outcome) {
          _log.info(
            '[RemoteBridge] sendToJob idle resume completed '
            'jobId=$jobId status=${outcome.status.name}',
          );
        }),
      );
      return {'ok': true, 'status': 'resumed'};
    },
    createNovel: createNovel,
    editNovel: editNovel,
    listChapters: listChapters,

    onUsageChanged: onUsageChanged,
  );
  coordinator.start();

  ref.onDispose(() {
    coordinator.stop();
  });

  // 触发自动恢复：读 app_settings 中凭证 → 免扫码恢复 bridge + 重挂 forwarder。
  // 非阻塞 — FutureProvider 异步执行，coordinator 不依赖恢复结果即可工作
  // （handler 已注册，bridge 启动后消息自然流入）。
  ref.read(remoteBridgeAutoRestoreProvider);

  return coordinator;
});
