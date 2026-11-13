// 职责: 把小说章节段落（R-10 稳定锚点）作为来源创建多模态生成任务并落库回链。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/novel_content_daos/chapter_paragraph_dao.dart
//   lib/shared/models/generation/task.dart
//   lib/shared/models/production/image_request.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import '../database/app_database.dart';
import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import '../models/ai_provider.dart';
import '../models/production/image_request.dart';
import '../utils/short_entity_id.dart';
import '../utils/short_entity_id_allocator.dart';
import 'storyboard/service.dart';

final _log = AppLogger.forModule('NovelMultimodalJobs');

/// 来源类型常量：小说章节段落发起的多模态任务统一打此标记。
const String novelChapterParagraphSourceType = 'chapter_paragraph';

/// 小说侧多模态任务提交服务：段落存在性校验 + 回链字段写入 + 生成任务落库。
///
/// 与 production 侧的 [ImageTaskService] 不同，这里只负责「创建任务行」这一步，
/// 不拉起提交/轮询编排；执行编排仍由对应 kind 的既有服务接管。
class NovelMultimodalJobService {
  NovelMultimodalJobService({
    required this.contentDatabase,
    required this.database,
  });

  /// 作品内容库：用于按 paragraphId 反查段落稳定锚点。
  final NovelContentDatabase contentDatabase;

  /// 应用库：持有 GenerationTaskDao，生成任务行的唯一写入入口。
  final AppDatabase database;

  /// 为章节段落提交一张插图任务，落库后返回任务行。
  ///
  /// - 先用 [ChapterParagraphDao.getByParagraphId] 校验段落存在，段落缺失直接抛
  ///   [StateError]，不静默兜底。
  /// - `sourceType='chapter_paragraph'`、`sourceId=paragraphId`，回链锚点
  ///   `{chapterId}#{paragraphId}` 写进 requestJson 顶层字段。
  Future<GenerationTask> submitIllustration({
    required String novelId,
    required String chapterId,
    required String paragraphId,
    required String prompt,
    required String providerId,
    required String modelId,
    String ratio = '1:1',
    String resolution = '1K',
    List<ProductionImageReference> references = const [],
  }) async {
    final paragraph = await contentDatabase.chapterParagraphDao
        .getByParagraphId(paragraphId);
    if (paragraph == null) {
      throw StateError(
        'chapter paragraph not found: $paragraphId (chapter=$chapterId)',
      );
    }
    final sourceAnchor = '$chapterId#$paragraphId';
    // providerType 是落库必需列，且执行编排依赖它选渠道协议；缺失即配置错误，
    // 与 production 图片服务一样抛 invalid_config，不静默兜底。
    final provider = await database.aiProviderDao.getById(providerId);
    if (provider == null ||
        !provider.enabled ||
        !provider.availableImageModels.contains(modelId)) {
      throw const StoryboardException('invalid_config');
    }
    final request = ImageGenerationRequest(
      ProductionImageRequest(
        providerId: providerId,
        modelId: modelId,
        originalPrompt: prompt,
        prompt: prompt,
        ratio: ratio,
        resolution: resolution,
        size: null,
        references: references,
      ),
      paragraphId: paragraphId,
      sourceAnchor: sourceAnchor,
    );
    late final String id;
    try {
      id = await insertWithShortEntityId(
        type: ShortEntityIdType.generationTask,
        tableName: 'generation_tasks',
        idExists: database.generationTaskDao.idExists,
        insert: (id) => database.generationTaskDao.create(
          GenerationTasksCompanion.insert(
            id: id,
            kind: GenerationKind.image,
            novelId: novelId,
            sourceType: novelChapterParagraphSourceType,
            sourceId: paragraphId,
            providerId: providerId,
            providerType: provider.type,
            modelId: modelId,
            requestJson: request,
            status: GenerationTaskStatus.prepared,
          ),
        ),
      );
    } catch (error, stack) {
      // 严格 INSERT 失败（段落/来源校验、主键碰撞耗尽）必须留 [DB] 诊断，不静默。
      _log.error(
        '[DB] generation_tasks INSERT source=chapter_paragraph '
        'paragraph=$paragraphId',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
    return (await database.generationTaskDao.getById(id))!;
  }

  /// 段落分镜任务骨架：小说侧暂无「段落 → 分镜」编排入口，先明确拒绝，
  /// 不为了凑方法去改动 production 编排；接入时在此补真实实现。
  Future<GenerationTask> submitStoryboard({
    required String novelId,
    required String chapterId,
    required String paragraphId,
    required String prompt,
    required String providerId,
    required String modelId,
  }) async {
    throw UnsupportedError(
      'submitStoryboard is not wired for novel chapter paragraphs yet',
    );
  }

  /// 段落语音任务骨架：小说侧暂无「段落 → 语音」编排入口，先明确拒绝，
  /// 不为了凑方法去改动 production 编排；接入时在此补真实实现。
  Future<GenerationTask> submitVoice({
    required String novelId,
    required String chapterId,
    required String paragraphId,
    required String prompt,
    required String providerId,
    required String modelId,
  }) async {
    throw UnsupportedError(
      'submitVoice is not wired for novel chapter paragraphs yet',
    );
  }
}
