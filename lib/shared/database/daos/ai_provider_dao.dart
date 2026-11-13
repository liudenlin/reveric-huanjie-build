// 职责: AI Provider 数据访问对象 — 封装所有 AI Provider 相关的数据库操作
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/models/ai_provider.dart

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';
import '../../services/credentials/credential_cipher_singleton.dart';

part 'ai_provider_dao.drift.dart';

final _log = AppLogger.forModule('AiProviderDao');

/// P0-C：敏感凭证写前加密（幂等；空值直通；加密失败上抛 → 写失败 fail-closed）。
Future<String> _encryptCredential(String value, String aad) async {
  if (value.isEmpty) {
    return value;
  }
  final cipher = credentialCipher;
  if (cipher.isEncrypted(value)) {
    return value;
  }
  return cipher.encrypt(value, aad: aad);
}

/// P0-C：敏感凭证读时解密；失败置空（无效凭证，不返回明文，fail-closed）。
/// null 直通（可空字段，如 secretAccessKey）。
Future<String?> _decryptCredential(String? value, String aad) async {
  if (value == null || value.isEmpty) {
    return value;
  }
  final cipher = credentialCipher;
  if (!cipher.isEncrypted(value)) {
    return value; // 旧明文兼容（迁移前）
  }
  try {
    return await cipher.decrypt(value, aad: aad);
  } catch (_) {
    return '';
  }
}

@DriftAccessor(tables: [AiProviders])
class AiProviderDao extends DatabaseAccessor<AppDatabase>
    with _$AiProviderDaoMixin {
  AiProviderDao(super.db);

  Future<List<AiProvider>> getAll() async {
    final rows = await (select(aiProviders)
          ..where((table) => table.deletedAt.equals(notDeletedSentinel))
          ..orderBy([
            (table) => OrderingTerm(
              expression: table.updatedAt,
              mode: OrderingMode.asc,
            ),
          ]))
        .get();
    return _decryptProviders(rows);
  }

  Stream<List<AiProvider>> watchAll() => (select(aiProviders)
          ..where((table) => table.deletedAt.equals(notDeletedSentinel))
          ..orderBy([(table) => OrderingTerm.asc(table.updatedAt)]))
      .watch()
      .asyncMap(_decryptProviders);

  Future<AiProvider?> getById(String id) async {
    final row = await (select(aiProviders)..where(
          (table) =>
              table.id.equals(id) & table.deletedAt.equals(notDeletedSentinel),
        ))
        .getSingleOrNull();
    return row == null ? null : _decryptProvider(row);
  }

  Future<void> upsert(AiProvider provider) async {
    try {
      await transaction(() async {
        final previous = await getById(provider.id);
        // P0-C：previous 为密文，解密后与内存明文比较（判断是否需暂停生成任务）。
        final previousApiKey = previous == null || previous.apiKey.isEmpty
            ? ''
            : await _decryptCredential(
                  previous.apiKey,
                  'aiProvider.apiKey',
                ) ??
                  '';
        if (previous != null &&
            (previousApiKey != provider.apiKey ||
                previous.effectiveBaseUrl.trim().replaceFirst(
                      RegExp(r'/+$'),
                      '',
                    ) !=
                    provider.effectiveBaseUrl.trim().replaceFirst(
                      RegExp(r'/+$'),
                      '',
                    ) ||
                previous.type != provider.type)) {
          await attachedDatabase.generationTaskDao.pauseForProvider(
            provider.id,
          );
        }
        // P0-C：secretAccessKey 可空，先计算加密值（公开字段不支持 field promotion）。
        final secretAccessKey = provider.secretAccessKey;
        final encryptedSecretAccessKey = secretAccessKey == null
            ? null
            : await _encryptCredential(
                secretAccessKey,
                'aiProvider.secretAccessKey',
              );
        await into(aiProviders).insertOnConflictUpdate(
          AiProvidersCompanion(
            id: Value(provider.id),
            name: Value(provider.name),
            builtin: Value(provider.builtin),
            type: Value(provider.type),
            enabled: Value(provider.enabled),
            // P0-C：敏感凭证写前加密。
            apiKey: Value(
              await _encryptCredential(provider.apiKey, 'aiProvider.apiKey'),
            ),
            baseUrl: Value(provider.baseUrl),
            models: Value(provider.models),
            imageModels: Value(provider.imageModels),
            videoModels: Value(provider.videoModels),
            audioModels: Value(provider.audioModels),
            embeddingModels: Value(provider.embeddingModels),
            temperature: Value(provider.temperature),
            maxTurns: Value(provider.maxTurns),
            reasoningEffort: Value(provider.reasoningEffort),
            proxyUrl: Value(provider.proxyUrl),
            proxyUsername: Value(provider.proxyUsername),
            proxyPassword: Value(
              await _encryptCredential(
                provider.proxyPassword,
                'aiProvider.proxyPassword',
              ),
            ),
            accessKeyId: Value(provider.accessKeyId),
            secretAccessKey: Value(encryptedSecretAccessKey),
            assetProjectName: Value(provider.assetProjectName),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] ai_providers INSERT/UPDATE id=${provider.id}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<AiProvider>> getAllIncludingDeleted() async {
    final rows = await select(aiProviders).get();
    return _decryptProviders(rows);
  }

  /// P0-C 迁移专用：读取**原始**行（敏感字段未解密），供 CredentialMigration
  /// 直接加密写回，绕过 [_decryptProvider] / [_encryptCredential] 的读写边界。
  Future<List<AiProvider>> getAllRawForMigration() => select(aiProviders).get();

  /// P0-C 迁移专用：直接把某行敏感字段写为密文（不经过幂等 / 解密边界）。
  ///
  /// [secretAccessKey] 为 null 时列保持不动（原始 NULL），不写 Value(null)。
  Future<void> updateRawCredentialsForMigration({
    required String id,
    required String apiKey,
    required String proxyPassword,
    required String? secretAccessKey,
    required bool hasSecretAccessKey,
  }) async {
    await (update(aiProviders)..where((table) => table.id.equals(id))).write(
      AiProvidersCompanion(
        apiKey: Value(apiKey),
        proxyPassword: Value(proxyPassword),
        secretAccessKey: hasSecretAccessKey
            ? Value(secretAccessKey)
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// P0-C：解密敏感字段后返回（旧明文 / 空值直通）。
  Future<AiProvider> _decryptProvider(AiProvider provider) async {
    if (provider.apiKey.isEmpty &&
        provider.proxyPassword.isEmpty &&
        (provider.secretAccessKey?.isEmpty ?? true)) {
      return provider;
    }
    return provider.copyWith(
      // copyWith：apiKey/proxyPassword 为直接值（String?），secretAccessKey 为 Value<String?>。
      apiKey:
          await _decryptCredential(provider.apiKey, 'aiProvider.apiKey') ?? '',
      proxyPassword: await _decryptCredential(
            provider.proxyPassword,
            'aiProvider.proxyPassword',
          ) ??
          '',
      secretAccessKey: Value(
        await _decryptCredential(
          provider.secretAccessKey,
          'aiProvider.secretAccessKey',
        ),
      ),
    );
  }

  Future<List<AiProvider>> _decryptProviders(List<AiProvider> rows) async {
    return <AiProvider>[for (final row in rows) await _decryptProvider(row)];
  }

  /// 更新现有配置，保留不在列表中的记录及其软删除状态。
  Future<void> saveAll(List<AiProvider> providers) async {
    await transaction(() async {
      for (final provider in providers) {
        await upsert(provider);
      }
    });
  }

  Future<int> softDelete(String id) async {
    try {
      return await (update(
        aiProviders,
      )..where((table) => table.id.equals(id))).write(
        AiProvidersCompanion(
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] ai_providers UPDATE softDelete id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<int> restore(String id) async {
    try {
      return await (update(
        aiProviders,
      )..where((table) => table.id.equals(id))).write(
        AiProvidersCompanion(
          deletedAt: Value(notDeletedSentinel),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] ai_providers UPDATE restore id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<int> hardDelete(String id) async {
    return (delete(aiProviders)..where((table) => table.id.equals(id))).go();
  }
}
