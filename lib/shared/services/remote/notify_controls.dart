// 职责: P0-B.3 任务3 — 远程 Run notify 受控通知（安全控制）。
//       远程 Job 的 `Run notify progress/question/complete/error` 是受控能力：
//       - 仅允许向当前 Job 绑定会话发送（不得指定任意目标用户/渠道）；
//       - 限制消息长度（超长拒绝/截断）；
//       - 限制发送频率（窗口内超限丢弃）；
//       - 敏感信息（token/api key/secret 等）脱敏后写入/转发。
//       本文件为纯 Dart 助手（无运行时依赖），供授权服务（鉴权侧）与
//       providers 的 notifyCallback（运行时侧）共用，可在纯 Dart 单测验证。
//
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/services/remote/run_permission_policy.dart
//   lib/shared/providers/remote_bridge_providers.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
library;

/// 单条通知内容最大长度（UTF-16 code unit；超长拒绝/截断，防刷屏与滥用）。
const int notifyMaxContentLength = 2000;

/// 单个 Job 在 [notifyWindowDuration] 内允许的最大通知条数（频率上限）。
const int notifyMaxPerWindow = 10;

/// 通知频率统计窗口。
const Duration notifyWindowDuration = Duration(seconds: 60);

/// 敏感键值对脱敏正则（token / api_key / secret / password / authorization /
/// bearer / access_token / refresh_token / credential / private_key /
/// client_secret 后跟 `=` 或 `:` 的值；以及**裸** `Bearer <token>` 头，无
/// `=`/`:` 分隔符）——防御性兜底，确保敏感凭证不进入通知内容（收件箱/IM
/// 转发均为外部可见）。
///
/// 两类匹配：
/// - `key[=:](bearer )?value`（如 `authorization: Bearer xxx`）；
/// - `\bbearer\s+value`（裸 JWT/Bearer 头，如 `Bearer abc.def.ghi`）。
final RegExp _notifySecretPattern = RegExp(
  r'((?:(?:token|api[_-]?key|secret|password|passwd|authorization|'
  r'access[_-]?token|refresh[_-]?token|credential|private[_-]?key|'
  r'client[_-]?secret)\s*[=:]\s*(?:(?:bearer)\s+)?)|(?:\bbearer\s+))\S+',
  caseSensitive: false,
);

/// 通知内容脱敏：敏感键值 → `<redacted>`。
String redactNotifyContent(String content) {
  if (content.isEmpty) {
    return content;
  }
  return content.replaceAllMapped(
    _notifySecretPattern,
    (m) => '${m.group(1)}<redacted>',
  );
}

/// 截断超长通知内容到 [maxLength]（UTF-16 code unit；防御性兜底）。
String truncateNotifyContent(String content, int maxLength) {
  if (content.length <= maxLength) {
    return content;
  }
  return content.substring(0, maxLength);
}

/// 频率判定：在 [window] 内已发生 >= [max] 次 → 返回 false（本次拒绝）。
///
/// [recent] 为最近已发送通知的时间戳（按时间先后）；[now] 为当前时间。
bool notifyFrequencyAllowed(
  List<DateTime> recent,
  DateTime now, {
  int max = notifyMaxPerWindow,
  Duration window = notifyWindowDuration,
}) {
  var count = 0;
  for (final t in recent) {
    if (now.difference(t) < window) {
      count += 1;
      if (count >= max) {
        return false;
      }
    }
  }
  return true;
}

/// 通知参数是否声明了**任意目标**（channel / chatId / userId）。
///
/// 受控通知仅允许向当前 Job 绑定会话发送；工具参数不得指定任意目标用户/
/// 渠道。返回违规原因（供鉴权拒绝审计），无违规返回 null。
///
/// 兼容字段名（顶层或 `options` 内）：`target_chat_id` / `target_user_id` /
/// `channel` / `channel_type` / `chat_id` / `user_id` / `chatId` / `userId`。
String? notifyTargetViolation(Map<String, dynamic>? arguments) {
  final opts = _notifyOptions(arguments);
  if (opts == null) {
    return null;
  }
  for (final key in const [
    'target_chat_id',
    'target_user_id',
    'channel',
    'channel_type',
    'chat_id',
    'user_id',
    'chatId',
    'userId',
  ]) {
    final value = opts[key];
    if (value is String && value.isNotEmpty) {
      return 'notify_target_forbidden: $key specified';
    }
    if (value is Map && value.isNotEmpty) {
      return 'notify_target_forbidden: $key specified';
    }
  }
  return null;
}

/// 通知内容长度是否违规（超长）。返回违规原因，无违规返回 null。
String? notifyLengthViolation(Map<String, dynamic>? arguments) {
  final opts = _notifyOptions(arguments);
  if (opts == null) {
    return null;
  }
  final content = opts['content'];
  if (content is String && content.length > notifyMaxContentLength) {
    return 'notify_too_long: ${content.length} > $notifyMaxContentLength';
  }
  return null;
}

/// 提取通知参数（`arguments['options']` 与 arguments 顶层**合并**）。
///
/// 受控通知的违规检测须同时覆盖顶层目标字段与 `options` 内字段——工具参数
/// 可能把 `target_chat_id`/`channel`/`content` 放在任一位置，只取 `options`
/// 会漏检顶层指定目标（P0-B.3 任务3）。合并时 options 覆盖顶层同名键。
Map<String, dynamic>? _notifyOptions(Map<String, dynamic>? arguments) {
  if (arguments == null) {
    return null;
  }
  final options = arguments['options'];
  if (options is Map) {
    return <String, dynamic>{
      ...arguments,
      ...Map<String, dynamic>.from(options),
    };
  }
  return arguments;
}
