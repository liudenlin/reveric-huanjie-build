// 职责: M2 四态正典服务 — 对话/工具产出的设定裁决与落位追踪。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (CanonEntries 表)
//   lib/shared/database/novel_content_daos/content_lock_dao.dart (CanonEntryDao)
//
// 四态语义（对齐 V1.0/V6.0 Canon 分层）：
//   canon       正式事实（已落位，受锁定保护）
//   discussion  讨论中（AI 对话产出，未裁决）
//   proposal    提案（已提出，待用户确认）
//   deprecated  废弃（被替代/否决，历史保留）
//
// 裁决流程：对话/工具产出默认落到 discussion/proposal →
//   propose() 由用户提升为 proposal →
//   canonize() 由用户确认提升为 canon（同时建议 addLock 保护）→
//   deprecate() 由用户否决/替代 → deprecated。
// 每个动作都记录来源（session/turn/decidedBy），可回溯。
import 'package:drift/drift.dart' hide Column;

import '../database/novel_content_database.dart';
import '../database/novel_content_daos/content_lock_dao.dart';
import 'content_lock_service.dart';

class CanonService {
  CanonService(this.db);

  final NovelContentDatabase db;

  CanonEntryDao get _dao => db.canonEntryDao;

  /// 对话/工具产出写入正典（默认 discussion 层，可指定初始层级）。
  Future<CanonEntry> record({
    required String resourceType,
    required String resourceId,
    String level = canonLevelDiscussion,
    String title = '',
    String fact = '',
    String source = '',
    String? sourceSessionId,
    String? sourceTurnId,
  }) async {
    final id = _newId();
    final now = DateTime.now();
    await _dao.upsert(
      CanonEntriesCompanion.insert(
        id: id,
        resourceType: resourceType,
        resourceId: resourceId,
        level: level,
        title: Value(title),
        source: source,
        sourceSessionId: Value(sourceSessionId),
        sourceTurnId: Value(sourceTurnId),
        fact: Value(fact),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return (await _dao.findById(id))!;
  }

  /// 用户裁决：一条正典条目的层级/内容更新（discussion→proposal/canon→deprecated）。
  Future<void> decide({
    required String entryId,
    required String level,
    String? decisionNote,
    String? decidedBy,
  }) {
    return (db.update(db.canonEntries)..where((t) => t.id.equals(entryId))).write(
      CanonEntriesCompanion(
        level: Value(level),
        decisionNote: Value(decisionNote ?? ''),
        decidedBy: Value(decidedBy ?? 'user'),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 提升为正式事实（canon），并可选建议锁定保护。
  Future<void> canonize({
    required String entryId,
    String? decisionNote,
    String? decidedBy,
    bool suggestLock = true,
    String? lockReason,
  }) async {
    await decide(
      entryId: entryId,
      level: canonLevelCanon,
      decisionNote: decisionNote,
      decidedBy: decidedBy,
    );
    if (suggestLock) {
      final entry = await _dao.findById(entryId);
      if (entry == null || entry.resourceId.isEmpty) return;
      // 幂等：已锁则不重复加锁。
      final existing = await db.contentLockDao.listActive();
      final alreadyLocked = existing.any(
        (l) =>
            l.resourceType == entry.resourceType &&
            l.resourceId == entry.resourceId,
      );
      if (!alreadyLocked) {
        final lockService = ContentLockService(db);
        await lockService.addLock(
          scope: lockScopeObject,
          resourceType: entry.resourceType,
          resourceId: entry.resourceId,
          reason: lockReason ?? '正典事实锁定保护（canon）',
          createdBy: 'user',
        );
      }
    }
  }

  /// 查询对象当前正典状态。
  Future<CanonEntry?> currentFor(String resourceType, String resourceId) =>
      _dao.currentFor(resourceType, resourceId);

  /// 该资源是否为正式事实（canon）。
  Future<bool> isCanon(String resourceType, String resourceId) async {
    final current = await _dao.currentFor(resourceType, resourceId);
    return current?.level == canonLevelCanon;
  }

  /// 列出所有正典条目。
  Future<List<CanonEntry>> listAll() => _dao.listAll();

  /// 被替代/否决 → 废弃（历史保留）。
  Future<void> deprecate(String entryId, {String? decisionNote}) =>
      _dao.deprecate(entryId, decisionNote: decisionNote);

  String _newId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = (DateTime.now().millisecondsSinceEpoch % 100000).toString();
    return 'cn_${ts}_$rand';
  }
}