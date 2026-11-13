// 职责: RemoteAuthorizationAuditStore 的 Drift（remote_authorization_audit 表）实现。
//       P0-B B3 —— 远程授权审计事件持久化（追加式），供按时间/用户/渠道/Job
//       查询与保留期限清理。
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/database/app_database.dart
//   lib/shared/providers/remote_bridge_providers.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
import 'dart:async';

import 'package:drift/drift.dart';

import '../logger/app_logger.dart';
import '../services/remote/remote_authorization_service.dart';
import 'app_database.dart';

final _log = AppLogger.forModule('RemoteAuthAudit');

/// 审计事件默认保留期限（天）。
///
/// 超过该期限的事件由 [DriftRemoteAuthorizationAuditStore.cleanupExpired]
/// 清理。审计表追加式、只增不删，靠保留期限策略控制体积。
const remoteAuthorizationAuditRetentionDays = 90;

/// Drift 表实现的审计持久化存储（替代内存环形缓冲的落库层）。
///
/// - `append`：追加一条事件（append-only）。**契约：内部吞掉异常，绝不向上抛**
///   —— 审计写入不在授权决策关键路径，失败不得影响授权判定（fail-closed 语义
///   下审计是决策之后的最佳努力记录）。
/// - `query`：按时间 / 用户 / 渠道 / Job 过滤，默认返回最近 [limit] 条（按
///   `at` 倒序）。
/// - `cleanupBefore` / `cleanupExpired`：保留期限清理，删除早于截止时间的事件。
class DriftRemoteAuthorizationAuditStore
    implements RemoteAuthorizationAuditStore {
  DriftRemoteAuthorizationAuditStore(this._db);

  final AppDatabase _db;

  /// 保留清理是否已调度（进程内一次）。
  bool _cleanupScheduled = false;

  /// 惰性调度一次保留期限清理（fire-and-forget，不阻塞 append、不向上抛）。
  ///
  /// 首个审计事件写入时触发一次 [cleanupExpired]；后续写入不再重复。清理
  /// 失败仅记录 —— 审计保留策略是尽力而为，绝不影响授权判定。
  void _scheduleStartupCleanup() {
    if (_cleanupScheduled) {
      return;
    }
    _cleanupScheduled = true;
    unawaited(
      cleanupExpired().catchError((Object error, StackTrace stackTrace) {
        _log.error(
          '[RemoteAuthAudit] startup cleanup failed',
          error: error,
          stackTrace: stackTrace,
        );
        return 0;
      }),
    );
  }

  @override
  Future<void> append(RemoteAuthorizationAuditEvent event) async {
    try {
      _scheduleStartupCleanup();
      await _db.into(_db.remoteAuthorizationAudit).insert(
        RemoteAuthorizationAuditCompanion.insert(
          event: event.event,
          channelType: event.channelType,
          chatId: event.chatId,
          userId: Value(event.userId),
          // 写入边界脱敏（纵深防御）：即使调用方绕过服务层直接 append，
          // 敏感 Token / API Key 也绝不落库。
          detail: Value(sanitizeRemoteAuthorizationDetail(event.detail)),
          jobId: Value(event.jobId),
          at: event.at,
        ),
      );
    } catch (error, stackTrace) {
      // 契约：审计写入失败仅记录，不向上抛（不影响授权判定）。
      _log.error(
        '[RemoteAuthAudit] append failed event=${event.event} '
        'channel=${event.channelType} chat=${event.chatId}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<List<RemoteAuthorizationAuditEvent>> query({
    DateTime? since,
    DateTime? until,
    String? channelType,
    String? chatId,
    String? userId,
    String? jobId,
    Set<String>? eventTypes,
    int limit = 200,
  }) async {
    try {
      final q = _db.select(_db.remoteAuthorizationAudit)
        ..orderBy([(t) => OrderingTerm.desc(t.at)]);
      if (since != null) {
        q.where((t) => t.at.isBiggerOrEqualValue(since));
      }
      if (until != null) {
        q.where((t) => t.at.isSmallerOrEqualValue(until));
      }
      if (channelType != null) {
        q.where((t) => t.channelType.equals(channelType));
      }
      if (chatId != null) {
        q.where((t) => t.chatId.equals(chatId));
      }
      if (userId != null) {
        q.where((t) => t.userId.equals(userId));
      }
      if (jobId != null) {
        q.where((t) => t.jobId.equals(jobId));
      }
      // 事件类型筛选（P0-B B4）：非空时仅保留命中事件类型的记录。
      if (eventTypes != null && eventTypes.isNotEmpty) {
        q.where((t) => t.event.isIn(eventTypes));
      }
      if (limit > 0) {
        q.limit(limit);
      }
      final rows = await q.get();
      return [for (final row in rows) _toEvent(row)];
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteAuthAudit] query failed — return empty (safe side)',
        error: error,
        stackTrace: stackTrace,
      );
      return const <RemoteAuthorizationAuditEvent>[];
    }
  }

  @override
  Future<int> cleanupBefore(DateTime cutoff) async {
    try {
      final deleted = _db
          .delete(_db.remoteAuthorizationAudit)
          ..where((t) => t.at.isSmallerThanValue(cutoff));
      return await deleted.go();
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteAuthAudit] cleanup failed cutoff=$cutoff',
        error: error,
        stackTrace: stackTrace,
      );
      return 0;
    }
  }

  /// 按保留期限清理过期事件（[remoteAuthorizationAuditRetentionDays]）。
  Future<int> cleanupExpired({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    return cleanupBefore(
      reference.subtract(
        const Duration(days: remoteAuthorizationAuditRetentionDays),
      ),
    );
  }

  RemoteAuthorizationAuditEvent _toEvent(RemoteAuthorizationAuditData row) {
    return RemoteAuthorizationAuditEvent(
      event: row.event,
      channelType: row.channelType,
      chatId: row.chatId,
      userId: row.userId,
      detail: row.detail,
      jobId: row.jobId,
      at: row.at,
    );
  }
}
