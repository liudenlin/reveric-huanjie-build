// 职责: 验证 McpCommandException 对 MCP server stderr 诊断的凭证脱敏，
// 防止上游 server 在 stderr 回显凭证时进入应用日志/错误展示。
// 关联文件:
//   lib/shared/services/mcp/client_adapter.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/mcp/client_adapter.dart';

void main() {
  group('McpCommandException diagnostic redaction', () {
    String render(Object cause, String diagnostic) =>
        McpCommandException(cause, diagnostic).toString();

    test('redacts Authorization: Bearer token', () {
      final out = render(
        StateError('boom'),
        'error: HTTP 401\nAuthorization: Bearer abc.def.ghi\nserver log',
      );
      expect(out, isNot(contains('abc.def.ghi')));
      expect(out, contains('<redacted>'));
      expect(out, contains('server log'));
    });

    test('redacts bare Bearer token', () {
      final out = render(
        StateError('boom'),
        'failed with Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig',
      );
      expect(out, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(out, contains('<redacted>'));
    });

    test('redacts key=value and key:value credential fields', () {
      final out = render(
        StateError('boom'),
        'config token=secretvalue123 endpoint=http://x\n'
        'api_key: abcdef1234567890\n'
        'refresh_token = rftok999\n'
        'client_secret: cs_abc',
      );
      expect(out, isNot(contains('secretvalue123')));
      expect(out, isNot(contains('abcdef1234567890')));
      expect(out, isNot(contains('rftok999')));
      expect(out, isNot(contains('cs_abc')));
      // 字段名保留，值被替换
      expect(out, contains('token=<redacted>'));
      expect(out, contains('api_key: <redacted>'));
    });

    test('keeps plain diagnostic content', () {
      const diagnostic =
          'unexpected exit code 1\nusage: mcp-server --port <n>';
      final out = render(StateError('boom'), diagnostic);
      expect(out, contains('unexpected exit code 1'));
      expect(out, contains('--port'));
      expect(out, isNot(contains('<redacted>')));
    });

    test('truncates overlong diagnostic', () {
      final long = List.filled(800, 'x').join('');
      final out = render(StateError('boom'), long);
      expect(out, contains('[truncated]'));
      expect(out.length, lessThan(650));
    });

    test('empty diagnostic passes through', () {
      final out = render(StateError('boom'), '');
      expect(out, contains('stderr: '));
    });
  });
}
