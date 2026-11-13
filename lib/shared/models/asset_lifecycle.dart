// 职责: R-43 资产生命周期状态机 — 定义资产从生成/上传到锁定/废弃的全档状态与合法推进规则。
// 关联文件:
//   lib/shared/database/app_database.dart (Assets.metadataJson 存 status)
//   lib/shared/services/image_library_service.dart (updateLifecycle/lifecycleOf)
//   lib/shared/models/asset_purpose.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（状态走 metadataJson，不动表结构）
//
// 验收（R-43）：正式形象被替换保留旧版本；状态 GENERATED/UPLOADED →
//   CANDIDATE → REVIEWED → APPROVED → LOCKED → DEPRECATED 单向推进；
//   LOCKED 后禁止直接降级（需显式 unlock）。

/// 资产生命周期状态常量（值即 JSON 里 `metadataJson.lifecycle` 的取值）。
const String assetLifecycleUploaded = 'uploaded';
const String assetLifecycleGenerated = 'generated';
const String assetLifecycleCandidate = 'candidate';
const String assetLifecycleReviewed = 'reviewed';
const String assetLifecycleApproved = 'approved';
const String assetLifecycleLocked = 'locked';
const String assetLifecycleDeprecated = 'deprecated';

/// 全部可取的资产生命周期档位（依推进顺序）。
const List<String> assetLifecycles = [
  assetLifecycleUploaded,
  assetLifecycleGenerated,
  assetLifecycleCandidate,
  assetLifecycleReviewed,
  assetLifecycleApproved,
  assetLifecycleLocked,
  assetLifecycleDeprecated,
];

/// metadataJson 缺省时按资产来源回退的初始档位：
/// 上传(UPLOADED) 与生成(GENERATED) 都属于「初始态」，不强行归并。
const String _fallbackUploaded = assetLifecycleUploaded;
const String _fallbackGenerated = assetLifecycleGenerated;

/// 读取到的 [value] 不在全量列表内（旧数据 / 手改 / 未来扩展）时回退。
/// [source] 为 'generated' 时回退生成态，否则回退上传态。
String normalizeAssetLifecycle(String? value, {String source = 'uploaded'}) {
  if (value == null) {
    return source == 'generated'
        ? _fallbackGenerated
        : _fallbackUploaded;
  }
  return assetLifecycles.contains(value) ? value : _fallbackUploaded;
}

/// 从当前档位允许推进到的所有下一档（可跳过中间档，但不可回退）。
/// - LOCKED 仅可回退到 REVIEWED（显式解锁）或推进到 DEPRECATED；
/// - DEPRECATED 是终态，无下一步；
/// - APPROVED 可推进到 LOCKED 或 DEPRECATED。
List<String> nextAssetLifecycles(String current) {
  return switch (current) {
    assetLifecycleUploaded || assetLifecycleGenerated => const [
      assetLifecycleCandidate,
      assetLifecycleReviewed,
      assetLifecycleApproved,
      assetLifecycleLocked,
      assetLifecycleDeprecated,
    ],
    assetLifecycleCandidate => const [
      assetLifecycleReviewed,
      assetLifecycleApproved,
      assetLifecycleLocked,
      assetLifecycleDeprecated,
    ],
    assetLifecycleReviewed => const [
      assetLifecycleApproved,
      assetLifecycleLocked,
      assetLifecycleDeprecated,
    ],
    assetLifecycleApproved => const [
      assetLifecycleLocked,
      assetLifecycleDeprecated,
    ],
    assetLifecycleLocked => const [
      assetLifecycleReviewed, // 显式解锁（需要 unlock:true + 原因）
      assetLifecycleDeprecated,
    ],
    assetLifecycleDeprecated => const [],
    _ => assetLifecycles,
  };
}

/// 是否允许从 [current] 推进到 [target]。
///
/// LOCKED → REVIEWED 属于「解锁」，必须显式传 [allowUnlock] 才放行，
/// 否则一律拒绝（防止锁定内容被静默降级后修改）。
bool canAdvanceAssetLifecycle(
  String current,
  String target, {
  bool allowUnlock = false,
  String? unlockReason,
}) {
  if (target == current) {
    return true;
  }
  if (current == assetLifecycleLocked && target == assetLifecycleReviewed) {
    if (!allowUnlock || (unlockReason == null || unlockReason.trim().isEmpty)) {
      return false;
    }
    return true;
  }
  if (current == assetLifecycleDeprecated) {
    return false; // 终态不可回退
  }
  return nextAssetLifecycles(current).contains(target);
}