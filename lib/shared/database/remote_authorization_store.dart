// 职责: RemoteAuthorizationStore 的 Drift（remote_authorizations 表）实现。
//       授权服务本体保持纯 Dart（仅依赖 RemoteAuthorizationStore 接口），
//       本实现把 JSON 语义映射到正式授权表，并承载 P0-B B2 旧 JSON 授权迁移
//       （M1 修复：原子迁移/故障区分/并发单飞）与 P0-B.1 M2 行级授权操作
//       （upsert/revoke/list/readActive，事务 + 部分唯一索引）。
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/database/app_database.dart
//   lib/shared/providers/remote_bridge_providers.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
//   .agents/rules/db-migration.md
import 'dart:convert';

import 'package:drift/drift.dart';

import '../logger/app_logger.dart';
import '../services/remote/remote_authorization_service.dart';
import 'app_database.dart';

final _log = AppLogger.forModule('RemoteAuthStore');

/// 旧 JSON 授权迁移完成标记（app_settings key）。
const remoteAuthorizationsMigratedKey = 'remote_authorizations_migrated_v5';

/// 旧 JSON 授权数据读取结果（M1：区分不存在/读取失败/损坏/正常）。
sealed class _LegacyJsonState {
  const _LegacyJsonState();
}

/// 键不存在或值为空字符串 —— 确无旧授权数据。
final class _LegacyJsonAbsent extends _LegacyJsonState {
  const _LegacyJsonAbsent();
}

/// 读取旧 JSON 抛异常 —— 存储故障，不得置标记，fail-closed 重试下次。
final class _LegacyJsonReadError extends _LegacyJsonState {
  const _LegacyJsonReadError(this.error);
  final Object error;
}

/// JSON 无法解析 / 非列表 / 含无效记录 —— 数据损坏，不得当空列表提交。
final class _LegacyJsonCorrupt extends _LegacyJsonState {
  const _LegacyJsonCorrupt(this.reason);
  final String reason;
}

/// 旧 JSON 正常解析出记录（可能为空列表 —— 确无授权）。
final class _LegacyJsonLoaded extends _LegacyJsonState {
  const _LegacyJsonLoaded(this.records);
  final List<RemoteAuthorizationRecord> records;
}

/// Drift 表实现的授权存储（替代 [AppSettingsRemoteAuthorizationStore]）。
class DriftRemoteAuthorizationStore extends RemoteAuthorizationStore {
  DriftRemoteAuthorizationStore(this._db);

  final AppDatabase _db;

  /// 迁移完成的内存缓存（避免每次读都查 settings）。
  bool _migrated = false;

  /// 迁移单飞（M1：并发触发时只有一个迁移事务生效）。
  Future<void>? _migrationInFlight;

  @override
  Future<String?> read(String key) async {
    if (key != remoteChannelAuthorizationsKey) {
      return null;
    }
    await _ensureMigrated();
    final rows = await _db.select(_db.remoteAuthorizations).get();
    return jsonEncode([
      for (final row in rows) _toRecord(row).toJson(),
    ]);
  }

  @override
  Future<void> write(String key, String value) async {
    if (key != remoteChannelAuthorizationsKey) {
      return;
    }
    await _ensureMigrated();
    // M2：非法 JSON 写入必须明确报错，绝不静默清空授权表。
    final records = _parseRecordsStrict(value);
    await _db.transaction(() async {
      await (_db.delete(_db.remoteAuthorizations)).go();
      for (final rec in records) {
        await _db.into(_db.remoteAuthorizations).insert(_companion(rec));
      }
    });
  }

  // ---- M2 行级授权操作（事务 + 部分唯一索引） ----

  @override
  Future<void> upsert(RemoteAuthorizationRecord record) async {
    await _ensureMigrated();
    await _db.transaction(() async {
      // 同一 (channel_type, chat_id, user_id) 至多一行（部分唯一索引）：
      // 先删旧身份行（含已撤销），再插入最新授权，避免唯一冲突。
      await (_db.delete(_db.remoteAuthorizations)..where((t) {
        return t.channelType.equals(record.channelType) &
            t.chatId.equals(record.chatId) &
            _userIdEquals(t, record.userId);
      })).go();
      await _db.into(_db.remoteAuthorizations).insert(_companion(record));
    });
  }

  @override
  Future<bool> revoke({
    required String channelType,
    required String chatId,
    String? userId,
    DateTime? at,
    String? revokedBy,
  }) async {
    await _ensureMigrated();
    final now = at ?? DateTime.now();
    final affected = await _db.transaction(() async {
      // 仅撤销活动记录（revoked_at IS NULL），行级 UPDATE，不触碰其他行。
      return (_db.update(_db.remoteAuthorizations)..where((t) {
        return t.channelType.equals(channelType) &
            t.chatId.equals(chatId) &
            _userIdEquals(t, userId) &
            t.revokedAt.isNull();
      })).write(
        RemoteAuthorizationsCompanion(
          revokedAt: Value(now),
          revokedBy: Value(revokedBy ?? 'local_user'),
        ),
      );
    });
    return affected > 0;
  }

  @override
  Future<List<RemoteAuthorizationRecord>> listAll({
    String? channelType,
    String? chatId,
  }) async {
    await _ensureMigrated();
    final query = _db.select(_db.remoteAuthorizations)
      ..orderBy([(t) => OrderingTerm.desc(t.grantedAt)]);
    if (channelType != null) {
      query.where((t) => t.channelType.equals(channelType));
    }
    if (chatId != null) {
      query.where((t) => t.chatId.equals(chatId));
    }
    final rows = await query.get();
    return [for (final row in rows) _toRecord(row)];
  }

  @override
  Future<List<RemoteAuthorizationRecord>> readActive({
    required String channelType,
    required String chatId,
    String? userId,
  }) async {
    await _ensureMigrated();
    final query = _db.select(_db.remoteAuthorizations)
      ..where((t) {
        return t.channelType.equals(channelType) &
            t.chatId.equals(chatId) &
            t.revokedAt.isNull() &
            _userIdMatches(t, userId);
      });
    final rows = await query.get();
    return [for (final row in rows) _toRecord(row)];
  }

  /// 部分唯一索引的用户身份相等判定（userId 为 null 匹配会话级行）。
  Expression<bool> _userIdEquals(RemoteAuthorizations t, String? userId) {
    if (userId == null) {
      return t.userId.isNull();
    }
    return t.userId.equals(userId);
  }

  /// 授权判定语义的 userId 匹配（与 RemoteAuthorizationRecord.matches 一致）。
  Expression<bool> _userIdMatches(RemoteAuthorizations t, String? userId) {
    final sessionWide = t.userId.isNull();
    if (userId == null) {
      return sessionWide;
    }
    return sessionWide | t.userId.equals(userId);
  }

  // ---- M1 旧 JSON → 表 惰性迁移（原子 / 故障区分 / 并发单飞） ----

  Future<void> _ensureMigrated() {
    if (_migrated) {
      return Future.value();
    }
    final inFlight = _migrationInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _doMigrate().whenComplete(() {
      _migrationInFlight = null;
    });
    _migrationInFlight = future;
    return future;
  }

  Future<void> _doMigrate() async {
    if (_migrated) {
      return;
    }
    // 1) 迁移标记读取（失败返回 null，不视为「已迁移」）。
    final marker = await _readMigrationMarker();
    if (marker == '1') {
      _migrated = true;
      return;
    }
    // 2) 旧 JSON 读取（区分不存在/读取失败/损坏/正常）。
    final state = await _readLegacyJson();
    switch (state) {
      case _LegacyJsonAbsent():
        await _markMigrated();
      case _LegacyJsonReadError():
        _log.error(
          '[RemoteAuthStore] legacy JSON read failed — skip migration, '
          'fail-closed (keep JSON, no marker)',
          error: state.error,
        );
        // P0-B.3 任务1：旧 JSON 读取失败不得正常结束迁移检查并继续提供旧
        // 授权表内容（否则 read() 静默返回空表，掩盖迁移失败）——显式上抛，
        // 使所有授权读取/写入进入明确的失败路径，保留原始 JSON。
        throw StateError(
          'legacy authorization JSON read failed: ${state.error}',
        );
      case _LegacyJsonCorrupt():
        _log.error(
          '[RemoteAuthStore] legacy JSON corrupt: ${state.reason} — '
          'skip migration, fail-closed (keep JSON, no marker)',
        );
        // P0-B.3 任务1：损坏 JSON 不得当作空授权提交（deny-by-default 不等于
        // 清空授权）、不得正常结束迁移检查——显式上抛进入失败路径，保留原始
        // JSON，修复后可重试迁移。
        throw StateError('legacy authorization JSON corrupt: ${state.reason}');
      case _LegacyJsonLoaded(:final records):
        await _importLegacyAtomically(records);
    }
  }

  /// 原子导入：清空表 + 导入 + 记录核对 + 迁移标记写入，同一事务完成。
  Future<void> _importLegacyAtomically(
    List<RemoteAuthorizationRecord> records,
  ) async {
    try {
      await _db.transaction(() async {
        await (_db.delete(_db.remoteAuthorizations)).go();
        for (final rec in records) {
          await _db.into(_db.remoteAuthorizations).insert(_companion(rec));
        }
        // 记录核对：导入行数与解析数必须一致（不一致则回滚）。
        final count = await _countRows();
        if (count != records.length) {
          throw StateError(
            'legacy migration count mismatch: expect ${records.length} got $count',
          );
        }
        await _db.appSettingsDao.set(
          key: remoteAuthorizationsMigratedKey,
          value: '1',
        );
      });
      _migrated = true;
      _log.info(
        '[RemoteAuthStore] legacy JSON migrated to remote_authorizations '
        '(${records.length} records)',
      );
    } catch (error, stackTrace) {
      // 事务已回滚：表保持原状（空 → 拒绝），标记未置，JSON 保留。
      _migrated = false;
      _log.error(
        '[RemoteAuthStore] legacy migration failed — transaction rolled back, '
        'keep JSON, fail-closed',
        error: error,
        stackTrace: stackTrace,
      );
      // P0-B.2 Fail-closed：迁移失败必须显式上抛，不得静默吞掉。
      // - read() 上抛 → 服务层 _loadAll 捕获后按空表拒绝（deny-by-default），
      //   并把错误写入 _lastStoreReadError（管理 UI 可区分「无授权」与
      //   「存储故障」，不再掩盖迁移失败）；
      // - write()/upsert()/revoke()/listAll()/readActive() 上抛 → 中止后续
      //   写入，杜绝「迁移失败后写入新授权，下次成功迁移清表重导旧 JSON
      //   覆写新授权」的静默数据一致性风险；
      // - _migrationInFlight 由 whenComplete 清空，下一次调用自动重试迁移。
      rethrow;
    }
  }

  Future<int> _countRows() async {
    final count = _db.remoteAuthorizations.id.count();
    final row = await (_db.selectOnly(_db.remoteAuthorizations)
          ..addColumns([count]))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<String?> _readMigrationMarker() async {
    try {
      return await _db.appSettingsDao.get(remoteAuthorizationsMigratedKey);
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteAuthStore] migration marker read failed — fail-closed '
        '(migration state unknown, keep JSON)',
        error: error,
        stackTrace: stackTrace,
      );
      // P0-B.3 任务1：迁移标记读取异常 = 迁移状态未知。必须显式上抛
      // （fail-closed），不得返回 null 与「标记不存在」同结果——否则后续
      // 可能走旧 JSON 重导分支，清表覆写已迁移的授权表（数据一致性风险）。
      // read()/write()/upsert()/revoke()/listAll()/readActive() 随之进入
      // 明确的失败路径，杜绝「迁移状态未知却继续提供旧授权表内容」。
      rethrow;
    }
  }

  /// 读取旧 JSON 并区分四种语义（M1）。
  Future<_LegacyJsonState> _readLegacyJson() async {
    String? raw;
    try {
      raw = await _db.appSettingsDao.get(remoteChannelAuthorizationsKey);
    } catch (error) {
      return _LegacyJsonReadError(error);
    }
    if (raw == null || raw.isEmpty) {
      return const _LegacyJsonAbsent();
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error) {
      return _LegacyJsonCorrupt('invalid JSON: $error');
    }
    if (decoded is! List) {
      return const _LegacyJsonCorrupt('not a JSON array');
    }
    final records = <RemoteAuthorizationRecord>[];
    for (var i = 0; i < decoded.length; i++) {
      final rec = RemoteAuthorizationRecord.fromJson(decoded[i]);
      if (rec == null) {
        // 任何无效记录都视为整体损坏：绝不当空/部分授权提交（fail-closed）。
        return _LegacyJsonCorrupt('item #$i is not a valid authorization record');
      }
      records.add(rec);
    }
    return _LegacyJsonLoaded(_dedupByIdentity(records));
  }

  /// 按身份 (channelType, chatId, userId) 去重，保留最后一次出现。
  ///
  /// 旧 JSON / 写入集合可能含同身份重复条目；迁移与全量替换都必须先按
  /// 身份折叠为唯一行，否则触发 (channel_type, chat_id, user_id) 部分唯一
  /// 索引冲突（M1/M2）。「取最后一条」保证后续条目覆盖前序（幂等重放安全）。
  List<RemoteAuthorizationRecord> _dedupByIdentity(
    List<RemoteAuthorizationRecord> records,
  ) {
    final result = <RemoteAuthorizationRecord>[];
    final indexByIdentity = <String, int>{};
    for (final rec in records) {
      final id = '${rec.channelType}|${rec.chatId}|${rec.userId}';
      final existing = indexByIdentity[id];
      if (existing == null) {
        indexByIdentity[id] = result.length;
        result.add(rec);
      } else {
        result[existing] = rec;
      }
    }
    return result;
  }

  Future<void> _markMigrated() async {
    try {
      await _db.appSettingsDao.set(
        key: remoteAuthorizationsMigratedKey,
        value: '1',
      );
      _migrated = true;
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteAuthStore] migration marker write failed — retry next',
        error: error,
        stackTrace: stackTrace,
      );
      _migrated = false;
    }
  }

  /// 严格解析写入的 JSON 数组（M2）：损坏/非列表/无效记录一律抛错。
  List<RemoteAuthorizationRecord> _parseRecordsStrict(String value) {
    Object? decoded;
    try {
      decoded = jsonDecode(value);
    } catch (error) {
      throw FormatException('authorization write value is not valid JSON: $error');
    }
    if (decoded is! List) {
      throw const FormatException('authorization write value is not a JSON array');
    }
    final result = <RemoteAuthorizationRecord>[];
    for (var i = 0; i < decoded.length; i++) {
      final rec = RemoteAuthorizationRecord.fromJson(decoded[i]);
      if (rec == null) {
        throw FormatException('authorization write item #$i is invalid');
      }
      result.add(rec);
    }
    return _dedupByIdentity(result);
  }

  RemoteAuthorizationsCompanion _companion(RemoteAuthorizationRecord rec) {
    return RemoteAuthorizationsCompanion.insert(
      channelType: rec.channelType,
      chatId: rec.chatId,
      userId: Value(rec.userId),
      scope: rec.scope.name,
      grantedAt: rec.grantedAt,
      revokedAt: Value(rec.revokedAt),
      displayName: Value(rec.displayName),
      grantedBy: Value(rec.grantedBy),
    );
  }

  RemoteAuthorizationRecord _toRecord(RemoteAuthorization row) {
    final scope = RemotePermissionScope.values.firstWhere(
      (e) => e.name == row.scope,
      orElse: () => RemotePermissionScope.read,
    );
    return RemoteAuthorizationRecord(
      channelType: row.channelType,
      chatId: row.chatId,
      userId: row.userId,
      scope: scope,
      grantedAt: row.grantedAt,
      revokedAt: row.revokedAt,
      displayName: row.displayName,
      grantedBy: row.grantedBy,
    );
  }
}
