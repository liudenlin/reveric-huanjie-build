// 职责: 定义生成任务类型、公共状态与图片/视频的不可变请求快照。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/type_converters.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/models/video/request.dart
import '../production/image_request.dart';
import '../audio/request.dart';
import '../video/request.dart';

enum GenerationKind { image, video, audio }

enum GenerationTaskStatus {
  prepared,
  uploading,
  submitting,
  submission_unknown,
  running,
  saving,
  action_required,
  reconciliation_required,
  completed,
  failed,
  cancelled,
  expired;

  bool get isTerminal =>
      const {completed, failed, cancelled, expired}.contains(this);
}

sealed class GenerationRequest {
  const GenerationRequest();
  GenerationKind get kind;
  String get modelId;
  Map<String, dynamic> toJson();

  factory GenerationRequest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported generation request');
    }
    final request = json['request'] as Map<String, dynamic>;
    return switch (GenerationKind.values.byName(json['kind'] as String)) {
      GenerationKind.audio => AudioGenerationRequest(
        AudioRequest.fromJson(request),
        // 旧 JSON（version=1 早期数据）没有这两个顶层字段，回退空串保持兼容。
        paragraphId: json['paragraphId'] as String? ?? '',
        sourceAnchor: json['sourceAnchor'] as String? ?? '',
      ),
      GenerationKind.image => ImageGenerationRequest(
        ProductionImageRequest.fromJson(request),
        paragraphId: json['paragraphId'] as String? ?? '',
        sourceAnchor: json['sourceAnchor'] as String? ?? '',
      ),
      GenerationKind.video => VideoGenerationRequest(
        VideoRequest.fromJson(request),
        inputs: (json['inputs'] as List)
            .map((value) => VideoInput.fromJson(value as Map<String, dynamic>))
            .toList(),
        paragraphId: json['paragraphId'] as String? ?? '',
        sourceAnchor: json['sourceAnchor'] as String? ?? '',
      ),
    };
  }
}

final class ImageGenerationRequest extends GenerationRequest {
  const ImageGenerationRequest(
    this.request, {
    this.paragraphId = '',
    this.sourceAnchor = '',
  });
  final ProductionImageRequest request;

  /// 段落稳定锚点 ID（R-10）；非空表示该任务由小说章节段落发起。
  final String paragraphId;

  /// 人类可读的回链锚点，形如 `{chapterId}#{paragraphId}`。
  final String sourceAnchor;
  @override
  GenerationKind get kind => GenerationKind.image;
  @override
  String get modelId => request.modelId;
  @override
  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    'request': request.toJson(),
    if (paragraphId.isNotEmpty) 'paragraphId': paragraphId,
    if (sourceAnchor.isNotEmpty) 'sourceAnchor': sourceAnchor,
  };
}

final class VideoGenerationRequest extends GenerationRequest {
  VideoGenerationRequest(
    this.request, {
    List<VideoInput> inputs = const [],
    this.paragraphId = '',
    this.sourceAnchor = '',
  }) : inputs = List.unmodifiable(inputs);
  final VideoRequest request;
  final List<VideoInput> inputs;

  /// 段落稳定锚点 ID（R-10）；非空表示该任务由小说章节段落发起。
  final String paragraphId;

  /// 人类可读的回链锚点，形如 `{chapterId}#{paragraphId}`。
  final String sourceAnchor;
  @override
  GenerationKind get kind => GenerationKind.video;
  @override
  String get modelId => request.modelId;
  @override
  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    'request': request.toJson(),
    'inputs': inputs.map((input) => input.toJson()).toList(),
    if (paragraphId.isNotEmpty) 'paragraphId': paragraphId,
    if (sourceAnchor.isNotEmpty) 'sourceAnchor': sourceAnchor,
  };
}

final class AudioGenerationRequest extends GenerationRequest {
  const AudioGenerationRequest(
    this.request, {
    this.paragraphId = '',
    this.sourceAnchor = '',
  });
  final AudioRequest request;

  /// 段落稳定锚点 ID（R-10）；非空表示该任务由小说章节段落发起。
  final String paragraphId;

  /// 人类可读的回链锚点，形如 `{chapterId}#{paragraphId}`。
  final String sourceAnchor;
  @override
  GenerationKind get kind => GenerationKind.audio;
  @override
  String get modelId => request.modelId;
  @override
  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    'request': request.toJson(),
    if (paragraphId.isNotEmpty) 'paragraphId': paragraphId,
    if (sourceAnchor.isNotEmpty) 'sourceAnchor': sourceAnchor,
  };
}
