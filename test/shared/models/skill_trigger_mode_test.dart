// 职责: R-33 Skill 触发模式测试 — auto/manual/always 枚举、默认值、容错回退、copyWith。
// 关联文件:
//   lib/shared/models/agent_skill.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（R-33）：SkillDefinition 携带 triggerMode（auto/manual/always），
//   旧数据缺字段回退 auto；copyWith 可切换模式而不动其它字段。

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/agent_skill.dart';

void main() {
  SkillDefinition makeSkill({String triggerMode = skillTriggerModeAuto}) {
    return SkillDefinition(
      id: 's_1',
      name: '章节写作',
      description: '写章节',
      prompt: '写',
      whenToUse: '写正文时',
      triggerMode: triggerMode,
    );
  }

  group('R-33 SkillTriggerMode', () {
    test('三种模式常量齐全', () {
      expect(skillTriggerModes, hasLength(3));
      expect(
        skillTriggerModes,
        containsAll([
          skillTriggerModeAuto,
          skillTriggerModeManual,
          skillTriggerModeAlways,
        ]),
      );
    });

    test('normalizeSkillTriggerMode：null/非法回退 auto', () {
      expect(normalizeSkillTriggerMode(null), skillTriggerModeAuto);
      expect(normalizeSkillTriggerMode('bogus'), skillTriggerModeAuto);
      expect(normalizeSkillTriggerMode(skillTriggerModeManual), skillTriggerModeManual);
      expect(normalizeSkillTriggerMode(skillTriggerModeAlways), skillTriggerModeAlways);
    });

    test('SkillDefinition 默认 triggerMode = auto', () {
      final skill = makeSkill();
      expect(skill.triggerMode, skillTriggerModeAuto);
    });

    test('copyWith 切换模式保持其它字段', () {
      final skill = makeSkill();
      final manual = skill.copyWith(triggerMode: skillTriggerModeManual);
      expect(manual.triggerMode, skillTriggerModeManual);
      expect(manual.name, skill.name);
      expect(manual.whenToUse, skill.whenToUse);
      expect(manual.prompt, skill.prompt);
      expect(manual.id, skill.id);
    });

    test('always 模式可表达"任务始终携带"', () {
      final skill = makeSkill(triggerMode: skillTriggerModeAlways);
      expect(skill.triggerMode, skillTriggerModeAlways);
    });
  });
}