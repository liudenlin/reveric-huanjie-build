// 职责: M2 内容级锁定服务 — 统一判定「某资源是否被锁定」。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (ContentLocks 表)
//   lib/shared/database/novel_content_daos/content_lock_dao.dart
//   lib/shared/agent/agent_tool_dispatcher.dart (executeTool 出口注入)
//
// 锁定粒度四级（scope）：
//   project  — 整个项目只读
//   module   — 某领域模块（人物/世界观/大纲/正文/设定）
//   object   — 某个具体实体（角色/章节/设定项）
//   field    — 某对象某字段（如角色「正式形象」）
//
// 判定规则（fail-closed，与 P0 安全壳一致）：
//   1. 与资源匹配的任一 active 锁命中 → 拒绝写入，返回 LockViolation
//   2. project 级锁匹配一切资源
//   3. module 级锁匹配 resourceType 相同的所有资源
//   4. object 级锁匹配 resourceType+resourceId
//   5. field 级锁在 object 命中之上再匹配 field
//   6. 锁本身不能由 AI 解除，只能作者显式解锁（authorUnlockable）
import 'package:drift/drift.dart' hide Column;

import '../database/novel_content_database.dart';
import '../utils/resource_path.dart';

/// 锁定命中结果：为 null 表示未锁定（允许写入）。
class LockViolation {
  const LockViolation({
    required this.lock,
    required this.matchedScope,
    required this.reason,
  });

  /// 命中的锁
  final ContentLock lock;

  /// 命中的粒度级别（project/module/object/field）
  final String matchedScope;

  /// 给用户的拒绝原因
  final String reason;

  Map<String, dynamic> toJson() => {
    'lockId': lock.id,
    'matchedScope': matchedScope,
    'reason': reason,
    'resourceType': lock.resourceType,
    'resourceId': lock.resourceId,
    'field': lock.field,
  };
}

class ContentLockService {
  ContentLockService(this.db);

  final NovelContentDatabase db;

  /// 检查写入是否被锁定。未锁定返回 null（可写）。
  /// [resourceType] 资源类型（novel/character/chapter/outline/item/relation/map…）
  /// [resourceId] 资源 ID（可为空，表示该类资源的通配检查）
  /// [field] 字段名（做字段级锁定时传入）
  Future<LockViolation?> checkWriteLock({
    required String resourceType,
    String? resourceId,
    String? field,
  }) async {
    // 1. project 级锁（锁定项目内一切资源，不按 resourceType 过滤）。
    //    锁的 resourceType 固定为 'novel'，但命中任何资源的写入。
    final projectLocks = await _activeLocks(
      scope: lockScopeProject,
      resourceType: '', // project 锁不区分资源类型
    );
    if (projectLocks.isNotEmpty) {
      return LockViolation(
        lock: projectLocks.first,
        matchedScope: lockScopeProject,
        reason: '项目已锁定，禁止 AI 写入。原因：${projectLocks.first.reason}',
      );
    }

    // 2. module 级锁（本资源类型整体锁定）
    final moduleLocks = await _activeLocks(
      scope: lockScopeModule,
      resourceType: resourceType,
    );
    if (moduleLocks.isNotEmpty) {
      return LockViolation(
        lock: moduleLocks.first,
        matchedScope: lockScopeModule,
        reason: '「${_typeLabel(resourceType)}」模块已锁定，禁止 AI 修改。原因：${moduleLocks.first.reason}',
      );
    }

    // 3. object 级锁（具体实体）
    if (resourceId != null && resourceId.isNotEmpty) {
      final objectLocks = await _activeLocks(
        scope: lockScopeObject,
        resourceType: resourceType,
        resourceId: resourceId,
      );
      if (objectLocks.isNotEmpty) {
        final lock = objectLocks.first;
        return LockViolation(
          lock: lock,
          matchedScope: lockScopeObject,
          reason: '该「${_typeLabel(resourceType)}」已被锁定，禁止 AI 写入。原因：${lock.reason}',
        );
      }

      // 4. field 级锁（对象字段）
      if (field != null && field.isNotEmpty) {
        final fieldLocks = await _activeLocks(
          scope: lockScopeField,
          resourceType: resourceType,
          resourceId: resourceId,
          field: field,
        );
        if (fieldLocks.isNotEmpty) {
          final lock = fieldLocks.first;
          return LockViolation(
            lock: lock,
            matchedScope: lockScopeField,
            reason: '该「${_typeLabel(resourceType)}」的「$field」字段已被锁定，禁止 AI 修改。原因：${lock.reason}',
          );
        }
      }
    }

    return null;
  }

  /// 便捷判定：按资源路径（如 chapters/c20、novels/n1、characters/hero）检查。
  Future<LockViolation?> checkWriteLockForPath(String resourcePath) {
    // 统一相对路径后按首段/次段推断类型与 id。
    final canonical = canonicalResourcePath(resourcePath);
    final segments = canonical
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      return checkWriteLock(resourceType: 'novel');
    }
    // 路径段名 → 资源类型（单数化）。
    final type = _resourceTypeFromSegment(segments[0]);
    if (segments.length >= 2) {
      return checkWriteLock(resourceType: type, resourceId: segments[1]);
    }
    // 只有类型段：整类资源的通配检查（module 级）。
    return checkWriteLock(resourceType: type);
  }

  /// 路径段名 → 锁定资源类型。
  String _resourceTypeFromSegment(String segment) => switch (segment) {
    'novels' => 'novel',
    'characters' => 'character',
    'chapters' => 'chapter',
    'outlines' => 'outline',
    'volumes' => 'volume',
    'items' => 'item',
    'relations' => 'relation',
    'maps' => 'map',
    'documents' => 'document',
    'locations' => 'location',
    'foreshadowings' => 'foreshadowing',
    _ => segment,
  };

  /// 新增锁（仅用户/系统可调用；AI 不可）。
  Future<void> addLock({
    required String scope,
    required String resourceType,
    String? resourceId,
    String? field,
    String reason = '',
    String createdBy = 'user',
    bool authorUnlockable = true,
  }) {
    return db.into(db.contentLocks).insert(
      ContentLocksCompanion.insert(
        id: _newId(),
        scope: scope,
        resourceType: resourceType,
        resourceId: Value(resourceId),
        field: Value(field),
        reason: Value(reason),
        createdBy: Value(createdBy),
        authorUnlockable: Value(authorUnlockable),
        active: const Value(true),
      ),
    );
  }

  /// 解锁（作者显式操作；AI 不可调用）。
  Future<void> removeLock(String lockId) {
    return (db.update(db.contentLocks)
          ..where((t) => t.id.equals(lockId)))
        .write(
      ContentLocksCompanion(
        active: const Value(false),
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 列出某资源触达的锁（供 UI 展示）。
  Future<List<ContentLock>> listLocks({
    String? resourceType,
    String? resourceId,
    bool activeOnly = true,
  }) {
    final query = db.select(db.contentLocks)
      ..where((t) {
        final e = t.active.equals(activeOnly);
        if (resourceType != null) {
          return e & t.resourceType.equals(resourceType);
        }
        return e;
      });
    if (resourceId != null) {
      query.where((t) => t.resourceId.equals(resourceId));
    }
    return query.get();
  }

  Future<List<ContentLock>> _activeLocks({
    required String scope,
    required String resourceType,
    String? resourceId,
    String? field,
  }) {
    final query = db.select(db.contentLocks)
      ..where((t) => t.active.equals(true) & t.scope.equals(scope));
    if (resourceType.isNotEmpty) {
      query.where((t) => t.resourceType.equals(resourceType));
    }
    if (resourceId != null && resourceId.isNotEmpty) {
      query.where((t) => t.resourceId.equals(resourceId));
    }
    if (field != null && field.isNotEmpty) {
      query.where((t) => t.field.equals(field));
    }
    return query.get();
  }

  String _typeLabel(String type) => switch (type) {
    'novel' => '项目',
    'character' => '人物',
    'chapter' => '章节',
    'outline' => '大纲',
    'volume' => '卷纲',
    'item' => '设定',
    'relation' => '关系',
    'map' => '地图',
    _ => type,
  };

  String _newId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = (DateTime.now().millisecondsSinceEpoch % 100000).toString();
    return 'lk_${ts}_$rand';
  }
}