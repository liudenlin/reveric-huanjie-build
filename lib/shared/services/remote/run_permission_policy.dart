// 职责: P0-B.1 S1 — Run 能力正向授权策略（统一五维规则）。
//       远程 Job 中 `Run` 工具的 command/subcommand 是否被允许执行，
//       替代 P0-B B0 的「黑名单」（runSensitiveSubcommands）为「正向白名单」：
//       只有经明确审核、且在 novel 数据模型内的写作能力才放行；
//       未分类 / 未知 / 外部执行 / 缺失绑定的一律 fail-closed 拒绝。
//
// 五维同时匹配（全部通过才 allow）:
//   1) 工具名 == 'Run'（本策略仅针对 Run 工具调用）
//   2) command/subcommand 已注册且已分类（未注册/未分类 → 拒绝）
//   3) 操作类型 read / write / execute / external
//   4) 资源所属作品（写操作必须绑定明确作品；null/空 workId 一律拒绝）
//   5) 远程用户授权 scope（read 操作任意 scope；write 需 write/all）
//
// 与 lib/shared/services/ai/tools_run.dart 的 `_runCommands` 分类保持同步：
// 新增/改名 Run 子命令时须同步本策略的 `_operationTypes`、
// `reviewedWorkWriteOperations` 与 `reviewedGlobalWriteOperations`，否则默认
// 拒绝（安全侧）。
//
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/services/ai/tools_run.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
library;

/// 远程用户授权 scope（与 [RemotePermissionScope] 一一对应，独立枚举避免循环依赖）。
enum RunPolicyScope {
  read,
  write,
  all;

  static RunPolicyScope fromName(String? name) {
    switch (name) {
      case 'write':
        return RunPolicyScope.write;
      case 'all':
        return RunPolicyScope.all;
      case 'read':
      default:
        return RunPolicyScope.read;
    }
  }
}

/// Run 子命令的操作类型（五维规则第 3 维）。
///
/// P0-B.3 任务2：`write` 细分为两种——
/// - [write]：作品域写（stagings/editing/novel.add-to-library），目标资源
///   必须绑定明确作品（workId），且目标资源须属于该作品；
/// - [globalWrite]：无作品归属的全局资源写（styles/themes/subagents/
///   agent-rules/agent-skills/operations.cancel），单独能力分类，**不得**
///   视作作品内资源（不要求 workId，但须经全局写白名单 + write/all scope）。
///
/// P0-B.3 任务3：`notify` 为远程受控通知能力（Run notify progress/question/
/// complete/error），与普通 Run 写操作**分开授权**（独立能力分类），仅在
/// 受控约束（绑定当前 Job 会话、长度/频率/敏感信息限制）下放行。
enum RunOperationType {
  read,
  write,
  globalWrite,
  notify,
  execute,
  external,
}

/// 五维判定结果。
class RunPolicyDecision {
  const RunPolicyDecision._({
    required this.allowed,
    required this.operationType,
    this.code,
    this.reason,
  });

  const RunPolicyDecision.allowed(RunOperationType operationType)
    : this._(allowed: true, operationType: operationType);

  const RunPolicyDecision.denied(String code, String reason)
    : this._(allowed: false, operationType: null, code: code, reason: reason);

  final bool allowed;
  final RunOperationType? operationType;

  /// 稳定拒绝码（deny 时非空）：unknown_subcommand / not_classified /
  /// write_not_reviewed / work_not_bound / scope_denied / requires_explicit_review。
  final String? code;
  final String? reason;

  bool get isAllowed => allowed;
}

/// Run 能力正向授权策略（纯函数，无运行时依赖，可直接单测）。
class RunPermissionPolicy {
  const RunPermissionPolicy._();

  /// 已注册子命令的操作类型分类（与 `_runCommands` 的 codemode/能力对应）。
  /// 未列出的子命令视为「未分类/未注册」→ 拒绝。
  /// - read：codemode read（只读，任意 scope 放行）
  /// - write：codemode write 且属 novel 数据模型
  /// - execute：执行外部进程/二进制（如 ffmpeg.execute）
  /// - external：调用外部服务/资源（如 mcp.call、generation.*、files.remove）
  static const Map<String, RunOperationType> _operationTypes = {
    // ---- read ----
    'assets.list': RunOperationType.read,
    'assets.read': RunOperationType.read,
    'stagings.schema': RunOperationType.read,
    'stagings.presets': RunOperationType.read,
    'stagings.sample': RunOperationType.read,
    'stagings.list': RunOperationType.read,
    'stagings.read': RunOperationType.read,
    'styles.list': RunOperationType.read,
    'styles.read': RunOperationType.read,
    'providers.list': RunOperationType.read,
    'providers.read': RunOperationType.read,
    'providers.models': RunOperationType.read,
    'operations.list': RunOperationType.read,
    'operations.read': RunOperationType.read,
    'operations.wait': RunOperationType.read,
    'files.list': RunOperationType.read,
    'files.read-text': RunOperationType.read,
    'files.read-video-metadata': RunOperationType.read,
    'files.read-audio-metadata': RunOperationType.read,
    'ffmpeg.capabilities': RunOperationType.read,
    'ffmpeg.probe': RunOperationType.read,
    'production.image-preset': RunOperationType.read,
    'editing.list': RunOperationType.read,
    'editing.read': RunOperationType.read,
    'agent-skills.list': RunOperationType.read,
    'agent-skills.search': RunOperationType.read,
    'agent-skills.get': RunOperationType.read,
    'agent-skills.reference-list': RunOperationType.read,
    'agent-skills.reference-get': RunOperationType.read,
    'themes.list': RunOperationType.read,
    'themes.read': RunOperationType.read,
    'subagents.list': RunOperationType.read,
    'agent-rules.list': RunOperationType.read,
    'agent-rules.read': RunOperationType.read,
    'sessions.list': RunOperationType.read,
    'sessions.read': RunOperationType.read,
    'sessions.search': RunOperationType.read,
    'sessions.get': RunOperationType.read,
    // ---- write：作品域写（novel 数据模型，目标资源须绑定明确作品）----
    'stagings.create': RunOperationType.write,
    'stagings.apply': RunOperationType.write,
    'stagings.write': RunOperationType.write,
    'stagings.restore': RunOperationType.write,
    'stagings.remove': RunOperationType.write,
    'stagings.preview': RunOperationType.write,
    'editing.create': RunOperationType.write,
    'editing.apply': RunOperationType.write,
    'editing.undo': RunOperationType.write,
    'editing.redo': RunOperationType.write,
    'editing.preview': RunOperationType.write,
    'editing.cleanup': RunOperationType.write,
    'novel.add-to-library': RunOperationType.write,
    // ---- globalWrite：无作品归属的全局资源写（单独能力分类）----
    'styles.create': RunOperationType.globalWrite,
    'styles.update': RunOperationType.globalWrite,
    'operations.cancel': RunOperationType.globalWrite,
    'themes.create': RunOperationType.globalWrite,
    'themes.update': RunOperationType.globalWrite,
    'themes.delete': RunOperationType.globalWrite,
    'themes.apply': RunOperationType.globalWrite,
    'subagents.create': RunOperationType.globalWrite,
    'subagents.update': RunOperationType.globalWrite,
    'subagents.delete': RunOperationType.globalWrite,
    'agent-rules.create': RunOperationType.globalWrite,
    'agent-rules.update': RunOperationType.globalWrite,
    'agent-rules.delete': RunOperationType.globalWrite,
    'agent-skills.create': RunOperationType.globalWrite,
    'agent-skills.update': RunOperationType.globalWrite,
    'agent-skills.delete': RunOperationType.globalWrite,
    'agent-skills.reference-create': RunOperationType.globalWrite,
    'agent-skills.reference-update': RunOperationType.globalWrite,
    'agent-skills.reference-move': RunOperationType.globalWrite,
    'agent-skills.reference-delete': RunOperationType.globalWrite,
    // ---- notify：远程受控通知（P0-B.3 任务3，独立能力分类）----
    'notify.progress': RunOperationType.notify,
    'notify.question': RunOperationType.notify,
    'notify.complete': RunOperationType.notify,
    'notify.error': RunOperationType.notify,
    // ---- write 但未明确审核（拒绝）----
    'assets.certify': RunOperationType.write,
    'production.capture-panorama': RunOperationType.write,
    'production.derive-view': RunOperationType.write,
    'production.split-grid': RunOperationType.write,
    'production.capture-frame': RunOperationType.write,
    'production.separate-audio': RunOperationType.write,
    'production.mute-video': RunOperationType.write,
    'production.trim-video': RunOperationType.write,
    'agent-skills.install': RunOperationType.write,
    // ---- execute / external（拒绝）----
    'ffmpeg.execute': RunOperationType.execute,
    'files.remove': RunOperationType.external,
    'mcp.call': RunOperationType.external,
    'production.generate-image': RunOperationType.external,
    'production.generate-video': RunOperationType.external,
    'production.generate-audio': RunOperationType.external,
    'character.generate-avatar': RunOperationType.external,
    'character.generate-photo': RunOperationType.external,
    'item.generate-photo': RunOperationType.external,
  };

  /// 经明确审核、允许远程执行的**作品域**写作能力（正向白名单，P0-B.3 任务2）。
  /// 目标资源必须绑定明确作品（workId），且目标资源须属于该作品（跨作品拒绝）。
  /// 未列入本集合的 write 操作一律拒绝（含 media/文件/外部生成/安装等高风险）。
  static const Set<String> reviewedWorkWriteOperations = {
    'stagings.create',
    'stagings.apply',
    'stagings.write',
    'stagings.restore',
    'stagings.remove',
    'stagings.preview',
    'editing.create',
    'editing.apply',
    'editing.undo',
    'editing.redo',
    'editing.preview',
    'editing.cleanup',
    'novel.add-to-library',
  };

  /// 经明确审核、允许远程执行的**全局资源**写作能力（P0-B.3 任务2：单独能力
  /// 分类，不得视作作品内资源）。无作品归属，不要求 workId；须 write/all scope。
  static const Set<String> reviewedGlobalWriteOperations = {
    'styles.create',
    'styles.update',
    'operations.cancel',
    'themes.create',
    'themes.update',
    'themes.delete',
    'themes.apply',
    'subagents.create',
    'subagents.update',
    'subagents.delete',
    'agent-rules.create',
    'agent-rules.update',
    'agent-rules.delete',
    'agent-skills.create',
    'agent-skills.update',
    'agent-skills.delete',
    'agent-skills.reference-create',
    'agent-skills.reference-update',
    'agent-skills.reference-move',
    'agent-skills.reference-delete',
  };

  /// 全部经审核的写能力（作品域 ∪ 全局），兼容旧引用（测试/审计遍历）。
  static const Set<String> reviewedWriteOperations = {
    ...reviewedWorkWriteOperations,
    ...reviewedGlobalWriteOperations,
  };

  /// 经明确审核、允许远程执行的**受控通知**能力（P0-B.3 任务3：独立能力
  /// 分类，与普通 Run 写操作分开授权）。运行进度/提问/完成/错误上报——
  /// 仅允许向当前 Job 绑定会话发送，且受长度/频率/敏感信息约束（由服务层
  /// 与运行时 notifyCallback 共同执行）。
  static const Set<String> reviewedNotifyOperations = {
    'notify.progress',
    'notify.question',
    'notify.complete',
    'notify.error',
  };

  /// 已注册但 codemode 标记为 denied / 未分类的子命令（须直接 Run/走专用入口，
  /// 不得在 Job 内远程执行）——与「未注册」区分，拒绝码 not_classified。
  /// 注：notify.* 已由 [reviewedNotifyOperations] 正向分类（P0-B.3 任务3
  /// 恢复受控通知），不再属于未分类集合。
  static const Set<String> _deniedCodemodeOperations = {
    'mcp.list',
    'mcp.search',
    'mcp.describe',
    'assets.view-image',
    'stagings.frames',
    'settings.open',
    'files.view-image',
    'ffmpeg.frames',
    'editing.frames',
    'map.draft',
  };

  /// 查询子命令操作类型；未注册/未分类返回 null。
  static RunOperationType? classify(String command, String subcommand) =>
      _operationTypes['$command.$subcommand'];

  /// 全部已分类的只读子命令（审计/测试用）。
  static Set<String> get readOperations => {
    for (final e in _operationTypes.entries)
      if (e.value == RunOperationType.read) e.key,
  };

  /// 全部已分类的**作品域**写子命令（审计/测试用；含未审核写）。
  static Set<String> get workWriteOperations => {
    for (final e in _operationTypes.entries)
      if (e.value == RunOperationType.write) e.key,
  };

  /// 全部已分类的**全局**写子命令（P0-B.3 任务2：无作品归属，单独分类）。
  static Set<String> get globalWriteOperations => {
    for (final e in _operationTypes.entries)
      if (e.value == RunOperationType.globalWrite) e.key,
  };

  /// 兼容别名：作品域写子命令（P0-B.3 前语义）。
  static Set<String> get writeOperations => workWriteOperations;

  /// 全部已分类的**受控通知**子命令（P0-B.3 任务3：独立能力分类）。
  static Set<String> get notifyOperations => {
    for (final e in _operationTypes.entries)
      if (e.value == RunOperationType.notify) e.key,
  };

  /// 作品域资源操作（目标资源位于当前作品内，read 或 write）。
  ///
  /// P0-B.3 任务2：这类操作的目标资源经 `SessionFiles(novelId: workId)`
  /// 关联作品（stagings/editing/assets/files）或为作品本身
  /// （novel.add-to-library）。服务层对这类操作追加目标资源归属校验——工具
  /// 参数显式声明的目标作品 ID 必须与可信作品 ID 一致，防止跨作品访问
  /// （作品 A 的 Job 读/改/删作品 B 资源）。未被本集合收录的只读操作
  /// （providers/operations/styles/themes/subagents/agent-rules/agent-skills/
  /// sessions 等）为应用级/全局资源，无作品归属，不做作品归属校验。
  static const Set<String> workScopedOperations = {
    // stagings（read + write）
    'stagings.schema',
    'stagings.presets',
    'stagings.sample',
    'stagings.list',
    'stagings.read',
    'stagings.create',
    'stagings.apply',
    'stagings.write',
    'stagings.restore',
    'stagings.remove',
    'stagings.preview',
    // editing（read + write）
    'editing.list',
    'editing.read',
    'editing.create',
    'editing.apply',
    'editing.undo',
    'editing.redo',
    'editing.preview',
    'editing.cleanup',
    // assets（read；assets.certify 为未审核写，已被策略拒绝，不进入校验）
    'assets.list',
    'assets.read',
    // files（read；files.remove 为外部调用，已被策略拒绝，不进入校验）
    'files.list',
    'files.read-text',
    'files.read-video-metadata',
    'files.read-audio-metadata',
    // novel（write：当前会话草稿作品 = workId）
    'novel.add-to-library',
  };

  /// 五维同时匹配判定。
  ///
  /// [workId] 为资源所属作品（第 4 维）。Run 写操作均为作品域操作；remote Job
  /// 绑定单一作品，故写操作必须显式绑定明确作品（非空 [workId]）——
  /// P0-B.2：null/空一律拒绝（work_not_bound），不得把「未绑定」当「Job 绑定」
  /// 放行，否则第 4 维形同虚设（调用方若不传 workId 即绕过作品归属校验）。
  static RunPolicyDecision evaluate({
    required String command,
    required String subcommand,
    String? workId,
    required RunPolicyScope scope,
  }) {
    final operation = '$command.$subcommand';
    final type = _operationTypes[operation];
    // 2) 未注册/未分类 → 拒绝（未知 与 未分类 分开，便于审计）。
    if (type == null) {
      if (_deniedCodemodeOperations.contains(operation)) {
        return RunPolicyDecision.denied(
          'not_classified',
          'run=$operation is registered but not classified (deny-by-default)',
        );
      }
      return RunPolicyDecision.denied(
        'unknown_subcommand',
        'run=$operation is not a registered Run subcommand',
      );
    }
    switch (type) {
      case RunOperationType.read:
        // 3+5) read 操作：任意 scope 放行（只读安全）。
        return RunPolicyDecision.allowed(RunOperationType.read);
      case RunOperationType.write:
        // 仅允许经明确审核的**作品域**写作能力（正向白名单，禁用黑名单）。
        if (!reviewedWorkWriteOperations.contains(operation)) {
          return RunPolicyDecision.denied(
            'write_not_reviewed',
            'run=$operation write is not an explicitly reviewed capability',
          );
        }
        // 4) 资源所属作品：作品域写操作必须绑定明确作品（P0-B.2：null 与
        //    空串一律拒绝，不得把「未绑定」当「Job 绑定作品」放行——否则第
        //    4 维形同虚设，任何无 workId 的写调用都会绕过作品归属校验）。
        //    P0-B.3 任务2：目标资源是否**属于**该 workId 由服务层资源校验器
        //    验证（本纯函数负责「作品已绑定」），跨作品访问在服务层拒绝。
        if (workId == null || workId.isEmpty) {
          return RunPolicyDecision.denied(
            'work_not_bound',
            'run=$operation write requires a bound work',
          );
        }
        // 5) 远程 scope：write 操作需 write/all。
        if (scope == RunPolicyScope.read) {
          return RunPolicyDecision.denied(
            'scope_denied',
            'run=$operation write requires remote scope write/all',
          );
        }
        return RunPolicyDecision.allowed(RunOperationType.write);
      case RunOperationType.globalWrite:
        // 全局资源写（无作品归属，P0-B.3 任务2：单独能力分类，不要求 workId）。
        if (!reviewedGlobalWriteOperations.contains(operation)) {
          return RunPolicyDecision.denied(
            'write_not_reviewed',
            'run=$operation global write is not an explicitly reviewed capability',
          );
        }
        // 5) 远程 scope：全局写操作需 write/all（应用级配置修改权限）。
        if (scope == RunPolicyScope.read) {
          return RunPolicyDecision.denied(
            'scope_denied',
            'run=$operation global write requires remote scope write/all',
          );
        }
        return RunPolicyDecision.allowed(RunOperationType.globalWrite);
      case RunOperationType.notify:
        // 受控通知（P0-B.3 任务3：独立能力分类，与普通 Run 写操作分开授权）。
        if (!reviewedNotifyOperations.contains(operation)) {
          return RunPolicyDecision.denied(
            'write_not_reviewed',
            'run=$operation notify is not an explicitly reviewed capability',
          );
        }
        // 5) 远程 scope：通知会写收件箱/转发 IM，属写入类能力，需 write/all。
        if (scope == RunPolicyScope.read) {
          return RunPolicyDecision.denied(
            'scope_denied',
            'run=$operation notify requires remote scope write/all',
          );
        }
        // 无作品归属：通知绑定当前 Job 会话，不要求 workId（跨作品无关）。
        // 目标/长度/频率/敏感信息等受控约束由服务层（鉴权侧）与运行时
        // notifyCallback（运行时侧）执行，见 notify_controls.dart。
        return RunPolicyDecision.allowed(RunOperationType.notify);
      case RunOperationType.execute:
      case RunOperationType.external:
        // 外部进程执行 / 外部服务调用：未经明确审核，一律拒绝（fail-closed）。
        return RunPolicyDecision.denied(
          'requires_explicit_review',
          'run=$operation is execute/external and requires explicit review (denied)',
        );
    }
  }
}
