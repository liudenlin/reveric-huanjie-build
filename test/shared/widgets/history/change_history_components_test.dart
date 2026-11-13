// 职责: 验证修改历史过滤逻辑 filterChangeCommits 的来源/资源/时间范围组合语义。
// 关联文件:
//   lib/shared/widgets/history/change_history_components.dart
//   lib/shared/services/working_overlay.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/widgets/history/change_history_components.dart';

ChangeCommit _commit(
  String id,
  DateTime createdAt, {
  String source = workingChangeSourceManual,
}) {
  return ChangeCommit(
    id: id,
    message: '$id-message',
    source: source,
    changeCount: 1,
    createdAt: createdAt,
  );
}

void main() {
  // 本地时区下锚定一组时间：跨 30+ 天，覆盖各档位样本。
  final t0 = DateTime(2026, 1, 1, 9, 0);
  final t1 = DateTime(2026, 1, 25, 9, 0);
  final t2 = DateTime(2026, 2, 1, 9, 0);
  final t3 = DateTime(2026, 2, 10, 9, 0);

  group('filterChangeCommits 时间范围', () {
    test('不传 from/to 时不过滤时间（向后兼容，全部返回）', () {
      final commits = [
        _commit('a', t0),
        _commit('b', t1),
        _commit('c', t2),
      ];
      final result = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.all,
      );
      expect(result.length, 3);
      expect(result.map((c) => c.id), ['a', 'b', 'c']);
    });

    test('仅传 to 时只保留该时间点及之前的记录（闭区间含端点）', () {
      final commits = [
        _commit('a', t0),
        _commit('b', t1),
        _commit('c', t2),
      ];
      final result = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.all,
        to: t1,
      );
      expect(result.map((c) => c.id), ['a', 'b']);
    });

    test('仅传 from 时只保留该时间点及之后的记录（闭区间含端点）', () {
      final commits = [
        _commit('a', t0),
        _commit('b', t1),
        _commit('c', t2),
      ];
      final result = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.all,
        from: t1,
      );
      expect(result.map((c) => c.id), ['b', 'c']);
    });

    test('from/to 同时给出时取交集，边界时刻本身被保留', () {
      final commits = [
        _commit('a', t0),
        _commit('b', t1),
        _commit('c', t2),
        _commit('d', t3),
      ];
      final result = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.all,
        from: t1,
        to: t2,
      );
      expect(result.map((c) => c.id), ['b', 'c']);
    });

    test('today / last7Days / last30Days 档位语义（按 created 时刻）', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final commits = [
        _commit('today', DateTime(today.year, today.month, today.day, 10)),
        _commit('yesterday', DateTime(today.year, today.month, today.day)
            .subtract(const Duration(days: 1))),
        _commit('six_days_ago', DateTime(today.year, today.month, today.day)
            .subtract(const Duration(days: 6))),
        _commit('seven_days_ago', DateTime(today.year, today.month, today.day)
            .subtract(const Duration(days: 7))),
        _commit('twenty_nine_days_ago', DateTime(today.year, today.month, today.day)
            .subtract(const Duration(days: 29))),
        _commit('thirty_days_ago', DateTime(today.year, today.month, today.day)
            .subtract(const Duration(days: 30))),
      ];

      // 近7天 = 今天 + 之前6天，共 7 个自然日；7天前(昨日往前第7天)被排除。
      final last7 = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.all,
        from: today.subtract(const Duration(days: 6)),
        to: today.add(const Duration(days: 1)),
      );
      expect(last7.map((c) => c.id),
          ['today', 'yesterday', 'six_days_ago']);

      // 近30天 = 今天 + 之前29天；30天前被排除。
      final last30 = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.all,
        from: today.subtract(const Duration(days: 29)),
        to: today.add(const Duration(days: 1)),
      );
      expect(
        last30.map((c) => c.id),
        [
          'today',
          'yesterday',
          'six_days_ago',
          'seven_days_ago',
          'twenty_nine_days_ago',
        ],
      );
    });
  });

  group('filterChangeCommits 来源 + 时间组合', () {
    test('来源与时间同时生效（组合筛选）', () {
      final commits = [
        _commit('ai-old', t0, source: workingChangeSourceAi),
        _commit('ai-recent', t2, source: workingChangeSourceAi),
        _commit('manual-recent', t2),
      ];
      final result = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.ai,
        from: t1,
        to: t3,
      );
      expect(result.map((c) => c.id), ['ai-recent']);
    });

    test('操作者两档来源互斥，manual 只匹配 manual_edit', () {
      final commits = [
        _commit('ai', t2, source: workingChangeSourceAi),
        _commit('manual', t2),
      ];
      expect(
        filterChangeCommits(
          commits: commits,
          filter: HistorySourceFilter.manual,
        ).map((c) => c.id),
        ['manual'],
      );
      expect(
        filterChangeCommits(
          commits: commits,
          filter: HistorySourceFilter.ai,
        ).map((c) => c.id),
        ['ai'],
      );
    });
  });

  group('filterChangeCommits 资源 + 时间范围', () {
    test('同时按资源与时间过滤时二者取交集', () {
      final commits = [
        _commit('c1', t0),
        _commit('c2', t1),
        _commit('c3', t2),
      ];
      final items = <ChangeCommitItem>[
        ChangeCommitItem(
          id: 'i1',
          commitId: 'c1',
          workingChangeId: 'w1',
          resourcePath: '第一章.md',
          resourceType: 'chapter',
          resourceId: 'r1',
          field: 'content',
          oldText: '旧',
          newText: '新',
          createdAt: t0,
        ),
        ChangeCommitItem(
          id: 'i2',
          commitId: 'c3',
          workingChangeId: 'w3',
          resourcePath: '第二章.md',
          resourceType: 'chapter',
          resourceId: 'r2',
          field: 'content',
          oldText: '旧',
          newText: '新',
          createdAt: t2,
        ),
      ];
      final result = filterChangeCommits(
        commits: commits,
        filter: HistorySourceFilter.all,
        resourceId: 'r1',
        resourceHistory: items,
        from: t0,
        to: t1,
      );
      expect(result.map((c) => c.id), ['c1']);
    });
  });
}