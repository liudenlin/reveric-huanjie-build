// 职责: P0-B.3 任务2 — 作品域 Run 写操作的目标资源归属校验器。
//       校验「工具参数中显式声明的目标作品/资源」是否与「可信 Job/Session
//       绑定的作品 workId」一致，防止跨作品越权（作品 A 的 Job 读/改/删
//       作品 B 的资源）。
//
// 设计要点:
//   - 可信作品 ID（workId）来自**持久化 Job/Session 的 novelId**（providers 层
//     经 ai_chat_session_dao 解析，或 start_job 的 novelId），不是工具参数。
//   - 实际目标资源 ID 来自**工具参数**（toolArguments 的
//     options.novelId / options.novel_id / options.workId / options.work_id）。
//   - 归属一致才放行：显式目标作品 ID == 可信作品 ID；未显式声明目标作品 ID 时，
//     stagings/editing 资源由 `SessionFiles(novelId: workId)` 关联作品、
//     novel.add-to-library 作用于当前会话草稿作品（= workId），均天然绑定可信
//     作品，无冲突目标 → 放行。
//   - 缺少归属信息 / 跨作品 → 拒绝（deny-by-default 安全侧）。
//
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/services/remote/run_permission_policy.dart
//   lib/shared/providers/remote_bridge_providers.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
library;

/// 作品域 Run 写操作的目标资源归属校验器。
///
/// 由 providers 层用 DAO 构造并注入 [RemoteAuthorizationService]；未注入时
/// 服务层回退 [DefaultRunResourceVerifier]（纯参数比对，可在纯 Dart 单测中
/// 验证跨作品拒绝）。资源级 ID 无校验器/无法解析归属 → 拒绝。
abstract interface class RunResourceVerifier {
  /// 校验目标资源归属。返回 true 放行；false 拒绝（跨作品/归属不一致）。
  ///
  /// [workId]：可信作品 ID（来自持久化 Job/Session 的 novelId）。作品域写
  /// 操作在策略第 4 维已保证非空；作品域读操作可能无绑定（非 Job 上下文），
  /// 此时为 null——校验器须安全处理（声明显式目标作品但无可信作品 → 拒绝）。
  /// [command]/[subcommand]：Run 子命令（用于识别资源类型）。
  /// [toolArguments]：即将执行工具的参数（用于解析目标资源 ID）。
  Future<bool> verifyWorkResource({
    required String? workId,
    required String command,
    required String subcommand,
    Map<String, dynamic>? toolArguments,
  });
}

/// 从 Run 工具参数中提取**显式声明的目标作品 ID**。
///
/// 兼容字段名（顶层或 `options` 内）：`novelId` / `novel_id` / `workId` /
/// `work_id`。仅接受非空字符串；未声明返回 null。这是「实际目标资源 ID 来自
/// 工具参数」的解析入口——若调用方试图在参数里声明一个属于其他作品的 ID，
/// 服务层据此拒绝。
String? extractTargetWorkId(Map<String, dynamic>? arguments) {
  if (arguments == null) {
    return null;
  }
  String? fromMap(Map<dynamic, dynamic> m) {
    for (final key in const ['novelId', 'novel_id', 'workId', 'work_id']) {
      final value = m[key];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  final direct = fromMap(arguments);
  if (direct != null) {
    return direct;
  }
  final options = arguments['options'];
  if (options is Map) {
    return fromMap(options);
  }
  return null;
}

/// 默认实现：纯参数比对（无 DAO 依赖，可用于纯 Dart 单测）。
///
/// 语义：
/// - 显式目标作品 ID 存在且 == 可信作品 ID → 放行；
/// - 显式目标作品 ID 存在且 != 可信作品 ID → 拒绝（跨作品访问）；
/// - 显式目标作品 ID 存在但无可信作品 ID（workId null/空）→ 拒绝（归属
///   无法证明，安全侧）；
/// - 未显式声明目标作品 ID → 资源天然绑定可信作品（stagings/editing/assets/
///   files 经 `SessionFiles(novelId: workId)`、novel.add-to-library 作用于当前
///   会话草稿作品 = workId），无冲突目标 → 放行。
class DefaultRunResourceVerifier implements RunResourceVerifier {
  const DefaultRunResourceVerifier();

  @override
  Future<bool> verifyWorkResource({
    required String? workId,
    required String command,
    required String subcommand,
    Map<String, dynamic>? toolArguments,
  }) async {
    final target = extractTargetWorkId(toolArguments);
    // 显式目标作品 ID 存在但无可信作品 ID → 归属不可证 → 拒绝（安全侧）。
    if (target != null && (workId == null || workId.isEmpty)) {
      return false;
    }
    // 跨作品：显式目标作品 ID 与可信作品不一致 → 拒绝（安全侧）。
    if (target != null && target != workId) {
      return false;
    }
    // 显式一致，或未显式声明（资源绑定可信作品）→ 放行。
    return true;
  }
}
