// 职责: 验证传输层 TLS 强制校验 —— 远程明文 http 拒绝、https 与回环豁免。
// P0-D B2。
// 关联文件:
//   lib/shared/services/transport_tls.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/transport_tls.dart';

void main() {
  group('isLoopbackHost', () {
    test('recognizes loopback hosts', () {
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('127.0.0.2'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
    });

    test('rejects non-loopback hosts', () {
      expect(isLoopbackHost('dav.example.com'), isFalse);
      expect(isLoopbackHost('192.168.1.10'), isFalse);
      expect(isLoopbackHost('10.0.0.5'), isFalse);
      expect(isLoopbackHost('s3.amazonaws.com'), isFalse);
    });
  });

  group('isCleartextRemoteEndpoint', () {
    test('accepts https regardless of host', () {
      expect(isCleartextRemoteEndpoint('https://dav.example.com'), isFalse);
      expect(isCleartextRemoteEndpoint('https://192.168.1.10'), isFalse);
      expect(isCleartextRemoteEndpoint('https://127.0.0.1:8080'), isFalse);
    });

    test('rejects remote cleartext http', () {
      expect(isCleartextRemoteEndpoint('http://dav.example.com'), isTrue);
      expect(isCleartextRemoteEndpoint('http://192.168.1.10'), isTrue);
      expect(isCleartextRemoteEndpoint('http://10.0.0.5/dav'), isTrue);
    });

    test('allows loopback cleartext http (local callback/dev)', () {
      expect(isCleartextRemoteEndpoint('http://127.0.0.1:8080'), isFalse);
      expect(isCleartextRemoteEndpoint('http://localhost:8080'), isFalse);
      expect(
        isCleartextRemoteEndpoint('http://127.0.0.1:9000/media/ref/x.png'),
        isFalse,
      );
      expect(isCleartextRemoteEndpoint('http://[::1]:8080'), isFalse);
    });

    test('leaves non-http schemes and malformed URLs to caller validation', () {
      expect(isCleartextRemoteEndpoint('ftp://dav.example.com'), isFalse);
      expect(isCleartextRemoteEndpoint(''), isFalse);
      expect(isCleartextRemoteEndpoint('not a url'), isFalse);
      expect(isCleartextRemoteEndpoint('http://'), isFalse);
    });
  });
}
