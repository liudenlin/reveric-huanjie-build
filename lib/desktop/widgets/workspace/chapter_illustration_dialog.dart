// 职责: 章节插图对话框 — 选择正文段落并输入画面描述，返回段落回链与提示词。
// 关联文件:
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/shared/utils/chapter_paragraph.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';

/// 单段落的展示项：稳定锚点 ID、章内序号与正文预览。
class ChapterParagraphOption {
  const ChapterParagraphOption({
    required this.paragraphId,
    required this.index,
    required this.text,
  });

  final String paragraphId;
  final int index;
  final String text;
}

/// 用户确认的插图选择：目标段落稳定锚点与画面提示词。
class ChapterIllustrationSelection {
  const ChapterIllustrationSelection({
    required this.paragraphId,
    required this.prompt,
  });

  final String paragraphId;
  final String prompt;
}

/// 打开章节插图对话框；段落为空时直接返回 null，不弹空壳。
Future<ChapterIllustrationSelection?> showChapterIllustrationDialog({
  required BuildContext context,
  required List<ChapterParagraphOption> paragraphs,
}) async {
  if (paragraphs.isEmpty) {
    return null;
  }
  return await showRevericDialog<ChapterIllustrationSelection>(
    context: context,
    builder: (context) => _ChapterIllustrationDialog(paragraphs: paragraphs),
  );
}

class _ChapterIllustrationDialog extends StatefulWidget {
  const _ChapterIllustrationDialog({required this.paragraphs});

  final List<ChapterParagraphOption> paragraphs;

  @override
  State<_ChapterIllustrationDialog> createState() =>
      _ChapterIllustrationDialogState();
}

class _ChapterIllustrationDialogState
    extends State<_ChapterIllustrationDialog> {
  late String _selectedId;
  late final TextEditingController _promptController;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.paragraphs.first.paragraphId;
    _promptController = TextEditingController(text: _promptFor(_selectedId));
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  String _promptFor(String paragraphId) {
    for (final option in widget.paragraphs) {
      if (option.paragraphId == paragraphId) {
        return option.text;
      }
    }
    return '';
  }

  void _handleParagraphChanged(String paragraphId) {
    setState(() {
      _selectedId = paragraphId;
      _promptController.text = _promptFor(paragraphId);
    });
  }

  void _confirm() {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      return;
    }
    Navigator.of(context).pop(
      ChapterIllustrationSelection(paragraphId: _selectedId, prompt: prompt),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return RevericDialog(
      title: context.t(LocaleKeys.workspaceIllustrateChapter),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.t(LocaleKeys.workspaceIllustrateParagraph),
              style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: RevericSpacing.xs),
            RevericSelect<String>(
              key: const Key('chapter-illustration-paragraph'),
              value: _selectedId,
              searchable: widget.paragraphs.length > 6,
              placeholder: context.t(LocaleKeys.workspaceIllustrateSelect),
              items: [
                for (final option in widget.paragraphs)
                  RevericSelectItem<String>(
                    value: option.paragraphId,
                    label: context.t(
                      LocaleKeys.workspaceIllustrateParagraphLabel,
                      namedArgs: {'number': '${option.index + 1}'},
                    ),
                    subtitle: _preview(option.text),
                  ),
              ],
              onChanged: _handleParagraphChanged,
            ),
            const SizedBox(height: RevericSpacing.lg),
            RevericTextField(
              controller: _promptController,
              fieldKey: const Key('chapter-illustration-prompt'),
              label: context.t(LocaleKeys.workspaceIllustratePrompt),
              hintText: context.t(LocaleKeys.workspaceIllustratePromptHint),
              multiline: true,
              minLines: 4,
              maxLines: 8,
            ),
          ],
        ),
      ),
      actions: [
        RevericButton.text(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: () => Navigator.of(context).pop(),
        ),
        RevericButton.primary(
          key: const Key('chapter-illustration-confirm'),
          label: context.t(LocaleKeys.workspaceIllustrateGenerate),
          onPressed: _confirm,
        ),
      ],
    );
  }
}

String _preview(String text) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return '…';
  }
  return normalized.length <= 72
      ? normalized
      : '${normalized.substring(0, 72)}…';
}
