// 职责: 验证图片生成错误分类能认出余额不足（402 / credit.insufficient）。
// 关联文件:
//   lib/shared/services/ai/image.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/ai/image.dart';

void main() {
  test('classifyAiImageError recognizes credit exhaustion phrases', () {
    expect(
      classifyAiImageError('insufficient credit'),
      AiImageErrorCode.credit,
    );
    expect(
      classifyAiImageError('credit.insufficient'),
      AiImageErrorCode.credit,
    );
    expect(
      classifyAiImageError('type=insufficient_quota'),
      AiImageErrorCode.credit,
    );
  });

  test('classifyAiImageError recognizes provider model denial', () {
    // 供应商 403 的 message 与 code 都要认得出，否则 403 会落到「检查 API Key」。
    expect(
      classifyAiImageError('model forbidden for user'),
      AiImageErrorCode.model_forbidden,
    );
    expect(
      classifyAiImageError('model.forbidden'),
      AiImageErrorCode.model_forbidden,
    );
  });
}
