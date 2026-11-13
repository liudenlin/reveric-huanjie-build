// 职责: AI 会话快照服务 — 导出某小说的全部会话与消息为可迁移 JSON，并在目标库合并导入以支持续写。
// 关联文件:
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/models/ai_chat_models.dart

import 'package:drift/drift.dart';

import '../../agent/client.dart';
import '../../database/app_database.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_chat_models.dart';
import 'session_persistence.dart';

final _log = AppLogger.forModule('SessionSnapshot');

/// 快照格式版本。当前仅支持读取 v1；更低或缺失版本按容错处理并告警。
const int _snapshotFormatVersion = 1;

/// 快照 checkpoint 的 metadata 标记键，用于标记该会话已中断并可恢复续写。
const String snapshotCheckpointKey = 'snapshot_checkpointed_at';

/// 会话快照导入结果 — 记录导入、合并、跳过与冲突数量，供调用方反馈。
class SessionImportResult {
  const SessionImportResult({
    required this.importedSessions,
    required this.mergedSessions,
    required this.skippedSessions,
    required this.importedMessages,
    required this.skippedMessages,
    required this.conflictMessages,
  });

  /// 目标库中不存在、整体新建的会话数。
  final int importedSessions;

  /// 目标库已存在同 id、按合并策略补齐缺失消息的会话数。
  final int mergedSessions;

  /// 目标库已存在同 id 且无缺失消息、因此未改动消息的会话数。
  final int skippedSessions;

  /// 实际写入目标库的消息条数。
  final int importedMessages;

  /// 目标库同会话内已存在而跳过的消息条数。
  final int skippedMessages;

  /// 消息 id 与目标库其它会话冲突、为避免覆盖而跳过的条数。
  final int conflictMessages;

  Map<String, dynamic> toJson() => {
        'imported_sessions': importedSessions,
        'merged_sessions': mergedSessions,
        'skipped_sessions': skippedSessions,
        'imported_messages': importedMessages,
        'skipped_messages': skippedMessages,
        'conflict_messages': conflictMessages,
      };
}

/// 会话快照服务（Session Snapshot Service）。
///
/// 快照是自包含 JSON：消息正文与 blocks 内联在快照里，不含本地文件路径外的
/// 外部依赖，可落临时目录后跨设备迁移并续写。这不是云端自动同步——上传/下载
/// 由调用方负责，本服务只做导出与导入合并。
class SessionSnapshotService {
  SessionSnapshotService({
    required this._appDatabase,
    required this._novelContentDatabase,
    required this._novelId,
  });

  final AppDatabase _appDatabase;
  final NovelContentDatabase _novelContentDatabase;
  final String _novelId;

  /// 导出该小说全部未删除会话（含子会话与 spawn/todo 等模式）为快照 JSON。
  ///
  /// 消息读取复用 [AiSessionPersistenceService.loadSessionMessages] 的快照语义
  /// （含 tool 运行历史恢复），不重复实现解码。
  Future<Map<String, dynamic>> exportNovelSessions({required String novelId}) async {
    final persistence = AiSessionPersistenceService(
      _appDatabase,
      novelId,
      novelContentDatabase: _novelContentDatabase,
    );
    final rows = await (_appDatabase.select(_appDatabase.aiChatSessions)
          ..where((table) =>
              table.novelId.equals(novelId) &
              table.deletedAt.equals(notDeletedSentinel))
          ..orderBy([
            (table) => OrderingTerm(expression: table.createdAt),
          ]))
        .get();

    final sessions = <Map<String, dynamic>>[];
    for (final row in rows) {
      final data = await persistence.loadSessionMessages(
        sessionId: row.id,
        novelDatabase: _novelContentDatabase,
      );
      sessions.add({
        'session_id': row.id,
        'parent_session_id': row.parentId,
        'title': row.title,
        'provider': row.provider,
        'model': row.model,
        'mode': row.mode,
        'agent_slug': row.agentSlug,
        'reasoning_effort': row.reasoningEffort,
        'metadata': row.metadata,
        'created_at': row.createdAt.toUtc().toIso8601String(),
        'updated_at': row.updatedAt.toUtc().toIso8601String(),
        'messages': data.messages.map((message) => message.toJson()).toList(),
      });
    }

    return {
      'format_version': _snapshotFormatVersion,
      'novel_id': novelId,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'session_count': sessions.length,
      'sessions': sessions,
    };
  }

  /// 将快照导入目标小说。
  ///
  /// 冲突策略（合并优先）：目标库已存在同 id 会话时，保留该会话现有消息，
  /// 仅追加目标库缺失的消息（同会话内按 id 判定缺失）；消息 id 在目标库其它
  /// 会话中已存在时视为冲突，跳过以避免 insertOrReplace 覆盖他人数据。
  /// 会话元数据以快照为准整体 upsert。未实现「生成新 id 并重映射 parentId」策略。
  Future<SessionImportResult> importNovelSessions({
    required Map<String, dynamic> snapshot,
    required String targetNovelId,
  }) async {
    final sessions = _validateSnapshot(snapshot, targetNovelId);
    final result = _ImportAccumulator();
    await _novelContentDatabase.transaction(() async {
      for (final entry in sessions) {
        final sessionId = entry['session_id'] as String;
        final messages = _decodeSnapshotMessages(entry['messages'], sessionId);
        final existing = await _appDatabase.aiChatSessionDao.getById(sessionId);
        await _upsertTargetSession(entry, targetNovelId);
        if (existing == null) {
          result.importedSessions += 1;
        }
        final existingIds = {
          for (final row
              in await _novelContentDatabase.aiChatMessageDao
                  .getBySession(sessionId))
            row.id,
        };
        final missing = <AiMessage>[];
        for (final message in messages) {
          if (existingIds.contains(message.id)) {
            result.skippedMessages += 1;
            continue;
          }
          // 消息主键是全局 id，先排除跨会话冲突，避免覆盖其它会话的行。
          final foreign = await _novelContentDatabase.aiChatMessageDao
              .getById(message.id);
          if (foreign != null) {
            result.conflictMessages += 1;
            _log.warning(
              'table=ai_chat_messages operation=SNAPSHOT_IMPORT_SKIP '
              'sessionId=$sessionId messageId=${message.id} '
              'reason=id_conflict_with_session=${foreign.sessionId}',
            );
            continue;
          }
          missing.add(message);
        }
        if (missing.isNotEmpty) {
          if (existing != null) {
            result.mergedSessionIds.add(sessionId);
          }
          result.importedMessages += missing.length;
          await _novelContentDatabase.aiChatMessageDao.upsertSessionMessages(
            messages: [
              for (var i = 0; i < missing.length; i++)
                _buildMessageCompanion(missing[i], sessionId, i),
            ],
          );
        } else if (existing != null) {
          result.skippedSessions++;
        }
      }
    });
    await _restoreActiveSession(sessions, targetNovelId);
    return result.build();
  }

  /// 标记会话为「已 checkpoint，可恢复续写」，复用现有保存逻辑落库。
  ///
  /// 仅写入 metadata 标记与消息，不新增 schema 列，不改变会话激活状态。
  Future<void> checkpointSession({required String sessionId}) async {
    final persistence = AiSessionPersistenceService(
      _appDatabase,
      _novelId,
      novelContentDatabase: _novelContentDatabase,
    );
    final session = await persistence.getSession(sessionId);
    if (session == null) {
      throw StateError('Snapshot checkpoint session not found: $sessionId');
    }
    final data = await persistence.loadSessionMessages(
      sessionId: sessionId,
      novelDatabase: _novelContentDatabase,
    );
    await _appDatabase.aiChatSessionDao.upsert(
      id: sessionId,
      novelId: _novelId,
      title: session.title,
      provider: session.provider,
      model: session.model,
      mode: session.mode,
      agentSlug: session.agentSlug,
      parentId: session.parentId,
      reasoningEffort: session.reasoningEffort,
      metadata: {
        ...?session.metadata,
        snapshotCheckpointKey: DateTime.now().toUtc().toIso8601String(),
      },
      createdAt: session.createdAt,
    );
    await persistence.saveMessages(
      sessionId: sessionId,
      messages: data.messages,
      novelDatabase: _novelContentDatabase,
    );
  }

  /// 校验快照结构与来源 novel_id。结构性缺失抛错；来源 novel 与目标不同仅告警，
  /// 以便把会话迁移到另一部小说（写入始终使用目标 novel_id）。
  List<Map<String, dynamic>> _validateSnapshot(
    Map<String, dynamic> snapshot,
    String targetNovelId,
  ) {
    final version = snapshot['format_version'];
    if (version is! int || version > _snapshotFormatVersion) {
      throw FormatException(
        'Unsupported session snapshot format_version: $version',
      );
    }
    if (version < _snapshotFormatVersion) {
      _log.warning(
        'operation=SNAPSHOT_IMPORT older format_version=$version '
        'expected=$_snapshotFormatVersion applying field defaults',
      );
    }
    final sourceNovelId = snapshot['novel_id'];
    if (sourceNovelId is! String || sourceNovelId.isEmpty) {
      throw const FormatException('Session snapshot is missing novel_id.');
    }
    if (sourceNovelId != targetNovelId) {
      _log.warning(
        'operation=SNAPSHOT_IMPORT novel_id_mismatch '
        'source=$sourceNovelId target=$targetNovelId',
      );
    }
    final rawSessions = snapshot['sessions'];
    if (rawSessions is! List) {
      throw const FormatException('Session snapshot is missing sessions array.');
    }
    final sessions = <Map<String, dynamic>>[];
    for (final item in rawSessions) {
      // 调用方可能传 Map<String, Object> 等字面量类型，统一规范化后再校验。
      if (item is Map) {
        _collectSessionEntry(Map<String, dynamic>.from(item), sessions);
        continue;
      }
      _log.warning(
        'operation=SNAPSHOT_IMPORT_SKIP reason=non_object_session_entry',
      );
    }
    return sessions;
  }

  /// 收集会话条目；缺 session_id 的损坏条目跳过而非整包失败（旧快照容错）。
  void _collectSessionEntry(
    Map<String, dynamic> entry,
    List<Map<String, dynamic>> sessions,
  ) {
    final id = entry['session_id'];
    if (id is! String || id.isEmpty) {
      _log.warning(
        'operation=SNAPSHOT_IMPORT_SKIP reason=missing_session_id '
        'title=${entry['title']}',
      );
      return;
    }
    sessions.add(entry);
  }

  /// 解码快照消息，容错旧快照：缺失 messages/字段时按空值与默认值兜底。
  List<AiMessage> _decodeSnapshotMessages(
    Object? raw,
    String sessionId,
  ) {
    if (raw is! List) {
      return const <AiMessage>[];
    }
    final messages = <AiMessage>[];
    for (final item in raw) {
      if (item is! Map) {
        _log.warning(
          'table=ai_chat_messages operation=SNAPSHOT_IMPORT_SKIP '
          'sessionId=$sessionId reason=non_object_message_entry',
        );
        continue;
      }
      final json = Map<String, dynamic>.from(item);
      final id = json['id'];
      final role = json['role'];
      if (id is! String ||
          id.isEmpty ||
          role is! String ||
          role.isEmpty) {
        _log.warning(
          'table=ai_chat_messages operation=SNAPSHOT_IMPORT_SKIP '
          'sessionId=$sessionId reason=missing_required_field',
        );
        continue;
      }
      // 旧快照可能缺 timestamp，用当前时间兜底，避免 fromJson 强转失败。
      final timestamp = json['timestamp'];
      if (timestamp is! String || timestamp.isEmpty) {
        json['timestamp'] = DateTime.now().toUtc().toIso8601String();
      }
      try {
        // jsonDecode 产生的嵌套 map 是 Map<String, Object?>，而消息/用量
        // fromJson 内部按 Map<String, dynamic> 强转，需先递归规范化键值类型。
        messages.add(AiMessage.fromJson(_normalizeJsonMap(json)));
      } catch (error, stackTrace) {
        _log.warning(
          'table=ai_chat_messages operation=SNAPSHOT_IMPORT_DECODE_FAILED '
          'sessionId=$sessionId messageId=$id '
          'error=$error stack=$stackTrace',
        );
      }
    }
    return messages;
  }

  /// 递归把 jsonDecode 结果的 Map/List 规范化为 fromJson 期望的强类型容器。
  Map<String, dynamic> _normalizeJsonMap(Map<dynamic, dynamic> map) {
    return map.map((key, value) => MapEntry(key.toString(), _normalizeJsonValue(value)));
  }

  Object? _normalizeJsonValue(Object? value) {
    if (value is Map<dynamic, dynamic>) {
      return _normalizeJsonMap(value);
    }
    if (value is List) {
      return [for (final element in value) _normalizeJsonValue(element)];
    }
    // 内存导出→导入不经 jsonEncode/jsonDecode 时，usage 仍是 AiUsage 对象；
    // AiMessage.fromJson 需要 Map，这里统一转成其 toJson 结果。
    if (value is AiUsage) {
      return value.toJson();
    }
    return value;
  }

  /// 用快照元数据整体 upsert 目标会话行，写入目标 novel_id。
  Future<void> _upsertTargetSession(
    Map<String, dynamic> entry,
    String targetNovelId,
  ) async {
    DateTime? parseTime(Object? value) =>
        value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
    await _appDatabase.aiChatSessionDao.upsert(
      id: entry['session_id'] as String,
      novelId: targetNovelId,
      title: entry['title'] is String ? entry['title'] as String : '',
      provider: entry['provider'] as String?,
      model: entry['model'] as String?,
      mode: entry['mode'] as String?,
      agentSlug: entry['agent_slug'] as String?,
      parentId: entry['parent_session_id'] as String?,
      reasoningEffort: entry['reasoning_effort'] as String?,
      metadata: entry['metadata'] is Map
          ? Map<String, dynamic>.from(entry['metadata'] as Map)
          : null,
      createdAt: parseTime(entry['created_at']),
    );
  }

  AiChatMessagesCompanion _buildMessageCompanion(
    AiMessage message,
    String sessionId,
    int index,
  ) {
    return AiChatMessagesCompanion.insert(
      id: message.id,
      sessionId: sessionId,
      role: message.role.name,
      type: Value(message.type.name),
      content: Value(message.content),
      blocks: Value(message.blocks.isEmpty ? null : message.blocks),
      metadata: Value(message.metadata),
      inputTokens: Value(message.usage?.inputTokens ?? 0),
      outputTokens: Value(message.usage?.outputTokens ?? 0),
      cacheReadTokens: Value(message.usage?.cacheReadTokens ?? 0),
      cacheWriteTokens: Value(message.usage?.cacheWriteTokens ?? 0),
      reasoningTokens: Value(message.usage?.reasoningTokens ?? 0),
      sequence: Value(index),
      createdAt: Value(message.timestamp),
    );
  }

  /// 导入前作为激活会话的顶层 chat 会话，导入后恢复激活指针以支持直接续写。
  Future<void> _restoreActiveSession(
    List<Map<String, dynamic>> sessions,
    String targetNovelId,
  ) async {
    if (targetNovelId != _novelId) {
      return;
    }
    String? activeId;
    for (final entry in sessions) {
      if (entry['parent_session_id'] != null) {
        continue;
      }
      if ((entry['mode'] as String?) == 'chat') {
        activeId = entry['session_id'] as String;
      }
    }
    if (activeId == null) {
      return;
    }
    await _novelContentDatabase.novelStateDao.setActiveChatSessionId(activeId);
  }
}

/// 导入计数累加器 — 合并同一会话的首次导入与后续合并计数，避免重复计数。
class _ImportAccumulator {
  int importedSessions = 0;
  final Set<String> mergedSessionIds = {};
  int skippedMessages = 0;
  int importedMessages = 0;
  int conflictMessages = 0;
  int skippedSessions = 0;

  SessionImportResult build() {
    return SessionImportResult(
      importedSessions: importedSessions,
      mergedSessions: mergedSessionIds.length,
      skippedSessions: skippedSessions,
      importedMessages: importedMessages,
      skippedMessages: skippedMessages,
      conflictMessages: conflictMessages,
    );
  }
}
