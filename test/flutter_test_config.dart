// 职责: 全局 widget 测试超时配置 —— 缩短 testWidgets 默认超时，让挂起用例
//   快速失败而非阻塞整轮回归。
// 关联文件:
//   无
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(Future<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    // 覆盖 testWidgets 的 10 分钟默认值：挂起用例在 2 分钟内失败，便于定位
    // 而非让整轮回归卡死（AGENTS.md「Flutter 测试必须串行 + 带超时」）。
    binding.defaultTestTimeout = const Timeout(Duration(minutes: 2));
  }
  await testMain();
}
