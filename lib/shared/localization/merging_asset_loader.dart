// 职责: 多文件 JSON 翻译资源加载器 — 按 namespace 拆分翻译文件后合并加载
// 关联文件:
//   assets/translations/en/*.json
//   assets/translations/zh-CN/*.json
//   lib/main.dart

import 'dart:convert';
import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';

class MergingAssetLoader extends AssetLoader {
  const MergingAssetLoader();

  static const _namespaces = [
    'a2ui',
    'account',
    'agent',
    'agent_studio',
    'agent_rule',
    'agent_shortcut',
    'agent_skill',
    'ai',
    'app',
    'assets',
    'audio',
    'canvas',
    'chapter',
    'character',
    'comment',
    'common',
    'condition',
    'connection',
    'council',
    'diff',
    'director',
    'editor',
    'entity',
    'entity_graph',
    'entity_search',
    'form',
    'heuristic',
    'history',
    'home',
    'library',
    'location',
    'map',
    'map_editor',
    'mobile',
    'monologue',
    'name_assistant',
    'onboarding',
    'plugin',
    'provider',
    'relation',
    'relation_dialog',
    'reading',
    'remote',
    'roleplay',
    'settings',
    'screenplay',
    'production',
    'sidebar',
    'subagent',
    'theater',
    'todo',
    'tool',
    'workspace',
  ];

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final localeDir = '$path/${locale.toStringWithSeparator(separator: "-")}';
    final namespaceMaps = await Future.wait([
      for (final ns in _namespaces) _loadNamespace('$localeDir/$ns.json'),
    ]);
    final merged = <String, dynamic>{};
    for (final map in namespaceMaps) {
      if (map != null) {
        merged.addAll(map);
      }
    }
    return merged;
  }

  /// 读取单个 namespace 的 JSON。使用 [rootBundle.load]（字节）而不是
  /// [rootBundle.loadString]，避免 CachingAssetBundle 的字符串缓存 Future
  /// 在 widget 测试的 FakeAsync 队列中跨 zone 复用导致翻译加载永不完成。
  Future<Map<String, dynamic>?> _loadNamespace(String key) async {
    try {
      final data = await rootBundle.load(key);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      // 缺失的 namespace 文件直接跳过，保持与原有行为一致。
      return null;
    }
  }
}
