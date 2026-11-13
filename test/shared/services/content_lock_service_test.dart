// M2 内容级锁定 + 四态正典 集成测试。
// 验证：四级锁定命中/放行、写路径检查、canonize 自动加锁、解锁。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/content_lock_service.dart';
import 'package:reveric/shared/services/canon_service.dart';

void main() {
  late NovelContentDatabase db;
  late ContentLockService lockService;
  late CanonService canonService;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    lockService = ContentLockService(db);
    canonService = CanonService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('ContentLockService 四级锁定', () {
    test('未锁定时写入放行', () async {
      final violation =
          await lockService.checkWriteLock(resourceType: 'chapter', resourceId: 'c1');
      expect(violation, isNull);
    });

    test('project 级锁命中一切资源', () async {
      await lockService.addLock(
        scope: lockScopeProject,
        resourceType: 'novel',
        reason: '全项目冻结',
      );
      final violation =
          await lockService.checkWriteLock(resourceType: 'chapter', resourceId: 'c1');
      expect(violation, isNotNull);
      expect(violation!.matchedScope, lockScopeProject);
      expect(violation.reason, contains('项目已锁定'));
    });

    test('module 级锁命中同类型资源', () async {
      await lockService.addLock(
        scope: lockScopeModule,
        resourceType: 'character',
        reason: '人物模块冻结',
      );
      final violation =
          await lockService.checkWriteLock(resourceType: 'character', resourceId: 'char1');
      expect(violation, isNotNull);
      expect(violation!.matchedScope, lockScopeModule);
    });

    test('object 级锁只命中该实体', () async {
      await lockService.addLock(
        scope: lockScopeObject,
        resourceType: 'chapter',
        resourceId: 'c20',
        reason: '第20章锁定',
      );
      final hit =
          await lockService.checkWriteLock(resourceType: 'chapter', resourceId: 'c20');
      expect(hit, isNotNull);

      final miss =
          await lockService.checkWriteLock(resourceType: 'chapter', resourceId: 'c21');
      expect(miss, isNull);
    });

    test('field 级锁命中对象字段', () async {
      await lockService.addLock(
        scope: lockScopeField,
        resourceType: 'character',
        resourceId: 'hero',
        field: 'officialImage',
        reason: '正式形象锁定',
      );
      final hit = await lockService.checkWriteLock(
        resourceType: 'character',
        resourceId: 'hero',
        field: 'officialImage',
      );
      expect(hit, isNotNull);
      expect(hit!.matchedScope, lockScopeField);

      final miss = await lockService.checkWriteLock(
        resourceType: 'character',
        resourceId: 'hero',
        field: 'biography',
      );
      expect(miss, isNull);
    });

    test('解锁后写入放行', () async {
      final lockId = 'lk_unittest_1';
      await db.contentLockDao.insertLock(
        ContentLocksCompanion.insert(
          id: lockId,
          scope: lockScopeObject,
          resourceType: 'chapter',
          resourceId: const Value('c20'),
          reason: const Value('第20章锁定'),
        ),
      );
      expect(
        await lockService.checkWriteLock(resourceType: 'chapter', resourceId: 'c20'),
        isNotNull,
      );
      await lockService.removeLock(lockId);
      expect(
        await lockService.checkWriteLock(resourceType: 'chapter', resourceId: 'c20'),
        isNull,
      );
    });

    test('checkWriteLockForPath 按路径分类检查', () async {
      await lockService.addLock(
        scope: lockScopeObject,
        resourceType: 'chapter',
        resourceId: 'c20',
        reason: '第20章路径锁定',
      );
      final hit = await lockService.checkWriteLockForPath('chapters/c20');
      expect(hit, isNotNull);
    });
  });

  group('CanonService 四态正典', () {
    test('record 默认落 discussion', () async {
      final entry = await canonService.record(
        resourceType: 'character',
        resourceId: 'hero',
        title: '主角',
        fact: '主角的设定',
        source: 'council',
      );
      expect(entry.level, canonLevelDiscussion);
    });

    test('decide 提升为 canon', () async {
      final entry = await canonService.record(
        resourceType: 'character',
        resourceId: 'hero',
        source: 'council',
      );
      await canonService.decide(entryId: entry.id, level: canonLevelCanon);
      expect(await canonService.isCanon('character', 'hero'), isTrue);
    });

    test('canonize 自动加锁且幂等', () async {
      final entry = await canonService.record(
        resourceType: 'character',
        resourceId: 'hero',
        source: 'user',
      );
      await canonService.canonize(entryId: entry.id, decidedBy: 'user');
      // 正典事实受到锁定保护。
      final violation =
          await lockService.checkWriteLock(resourceType: 'character', resourceId: 'hero');
      expect(violation, isNotNull);

      // 幂等：重复 canonize 不再重复加锁。
      await canonService.canonize(entryId: entry.id, decidedBy: 'user');
      final locks = await db.contentLockDao.listActive();
      final heroLocks = locks
          .where(
            (l) =>
                l.resourceType == 'character' && l.resourceId == 'hero',
          )
          .length;
      expect(heroLocks, 1);
    });

    test('deprecate 后不再是 canon', () async {
      final entry = await canonService.record(
        resourceType: 'item',
        resourceId: 'magic',
        source: 'user',
      );
      await canonService.canonize(entryId: entry.id);
      await canonService.deprecate(entry.id, decisionNote: '被更优设定替代');
      expect(await canonService.isCanon('item', 'magic'), isFalse);
    });
  });
}