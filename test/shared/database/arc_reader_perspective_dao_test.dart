// 职责: M6b/M6c DAO 读写测试 — 覆盖迁移测试未覆盖的方法路径：
//       ArcDao.listByType / listByRelatedObject / getById；
//       ReaderPerspectiveDao.listBySubject / updateState / getById。
// 关联文件:
//   lib/shared/database/novel_content_daos/arc_dao.dart
//   lib/shared/database/novel_content_daos/reader_perspective_dao.dart
//   lib/shared/database/novel_content_database.dart

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';

void main() {
  late NovelContentDatabase db;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  group('ArcDao', () {
    test('listByType 过滤类型并按 sortOrder 排序', () async {
      await db.arcDao.upsert(
        ArcsCompanion.insert(
          id: 'a1',
          projectId: const Value('proj'),
          type: arcTypeMain,
          title: const Value('主线A'),
          sortOrder: const Value(2),
        ),
      );
      await db.arcDao.upsert(
        ArcsCompanion.insert(
          id: 'a2',
          projectId: const Value('proj'),
          type: arcTypeSub,
          title: const Value('支线B'),
          sortOrder: const Value(1),
        ),
      );
      await db.arcDao.upsert(
        ArcsCompanion.insert(
          id: 'a3',
          projectId: const Value('proj'),
          type: arcTypeMain,
          title: const Value('主线C'),
          sortOrder: const Value(1),
        ),
      );

      final mains = await db.arcDao.listByType('proj', arcTypeMain);
      expect(mains.map((r) => r.id).toList(), ['a3', 'a1']); // sortOrder 升序
      expect(mains.every((r) => r.type == arcTypeMain), isTrue);
    });

    test('listByRelatedObject 按关联对象反查（角色弧/伏笔弧）', () async {
      await db.arcDao.upsert(
        ArcsCompanion.insert(
          id: 'char_arc',
          projectId: const Value('proj'),
          type: arcTypeCharacter,
          title: const Value('林晚成长弧'),
          relatedObjectType: const Value('character'),
          relatedObjectId: const Value('c_hero'),
        ),
      );
      await db.arcDao.upsert(
        ArcsCompanion.insert(
          id: 'fore_arc',
          projectId: const Value('proj'),
          type: arcTypeForeshadowing,
          title: const Value('吊坠伏笔'),
          relatedObjectType: const Value('foreshadowing'),
          relatedObjectId: const Value('f_1'),
        ),
      );

      final heroArcs = await db.arcDao.listByRelatedObject('c_hero');
      expect(heroArcs, hasLength(1));
      expect(heroArcs.single.id, 'char_arc');
      expect(heroArcs.single.relatedObjectType, 'character');
    });

    test('getById 取回完整行（含可空章节锚点）', () async {
      await db.arcDao.upsert(
        ArcsCompanion.insert(
          id: 'a1',
          projectId: const Value('proj'),
          type: arcTypeMain,
          title: const Value('主线'),
          goal: const Value('夺回星核'),
          status: const Value(arcStatusActive),
          startChapterId: const Value('ch_1'),
          endChapterId: const Value('ch_9'),
        ),
      );
      final arc = (await db.arcDao.getById('a1'))!;
      expect(arc.projectId, 'proj');
      expect(arc.goal, '夺回星核');
      expect(arc.status, arcStatusActive);
      expect(arc.startChapterId, 'ch_1');
      expect(arc.endChapterId, 'ch_9');
    });
  });

  group('ReaderPerspectiveDao', () {
    test('listBySubject 按主体过滤（reader / character:<id>）', () async {
      await db.readerPerspectiveDao.upsert(
        ReaderPerspectivesCompanion.insert(
          id: 'rp_1',
          factId: 'f_1',
          subject: 'reader',
          state: const Value(readerPerspectiveStateMisled),
          storyTime: const Value('卷1第3章'),
          evidence: const Value('ch_3: 误导'),
        ),
      );
      await db.readerPerspectiveDao.upsert(
        ReaderPerspectivesCompanion.insert(
          id: 'rp_2',
          factId: 'f_1',
          subject: 'character:c_hero',
          state: const Value(readerPerspectiveStateAware),
          storyTime: const Value('卷2第5章'),
        ),
      );

      final readerView = await db.readerPerspectiveDao.listBySubject('reader');
      expect(readerView, hasLength(1));
      expect(readerView.single.state, readerPerspectiveStateMisled);

      final heroView =
          await db.readerPerspectiveDao.listBySubject('character:c_hero');
      expect(heroView, hasLength(1));
      expect(heroView.single.state, readerPerspectiveStateAware);
    });

    test('updateState 迁移认知状态并更新 updatedAt', () async {
      await db.readerPerspectiveDao.upsert(
        ReaderPerspectivesCompanion.insert(
          id: 'rp_1',
          factId: 'f_1',
          subject: 'reader',
          state: const Value(readerPerspectiveStateUnknown),
        ),
      );
      await db.readerPerspectiveDao.updateState('rp_1', readerPerspectiveStateRevealed);
      final rp = (await db.readerPerspectiveDao.getById('rp_1'))!;
      expect(rp.state, readerPerspectiveStateRevealed);
      expect(rp.updatedAt, isNotNull);
    });
  });
}