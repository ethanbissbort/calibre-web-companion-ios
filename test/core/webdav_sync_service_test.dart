import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calibre_web_companion/core/services/webdav_sync_service.dart';

DioException _dioWithStatus(int statusCode) {
  final requestOptions = RequestOptions(path: '/progress.json');
  return DioException(
    requestOptions: requestOptions,
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: requestOptions,
      statusCode: statusCode,
    ),
  );
}

DioException _dioWithoutResponse(DioExceptionType type) {
  return DioException(
    requestOptions: RequestOptions(path: '/progress.json'),
    type: type,
  );
}

void main() {
  group('classifyWebDavReadError', () {
    test('404 is the legitimate first-run "file does not exist yet" case', () {
      expect(
        classifyWebDavReadError(_dioWithStatus(HttpStatus.notFound)),
        WebDavFetchStatus.notFound,
      );
    });

    test('410 Gone is also treated as not found', () {
      expect(
        classifyWebDavReadError(_dioWithStatus(HttpStatus.gone)),
        WebDavFetchStatus.notFound,
      );
    });

    test('auth failures are errors, never "empty"', () {
      for (final code in [
        HttpStatus.unauthorized,
        HttpStatus.forbidden,
        HttpStatus.proxyAuthenticationRequired,
      ]) {
        expect(
          classifyWebDavReadError(_dioWithStatus(code)),
          WebDavFetchStatus.failed,
          reason: 'HTTP $code must not be treated as an empty sync file',
        );
      }
    });

    test('server and other unexpected statuses are errors', () {
      for (final code in [
        HttpStatus.badRequest,
        HttpStatus.conflict,
        HttpStatus.internalServerError,
        HttpStatus.badGateway,
        HttpStatus.serviceUnavailable,
        HttpStatus.insufficientStorage,
      ]) {
        expect(
          classifyWebDavReadError(_dioWithStatus(code)),
          WebDavFetchStatus.failed,
          reason: 'HTTP $code must not be treated as an empty sync file',
        );
      }
    });

    test('transport failures without a response are errors', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.badCertificate,
        DioExceptionType.connectionError,
        DioExceptionType.cancel,
        DioExceptionType.unknown,
      ]) {
        expect(
          classifyWebDavReadError(_dioWithoutResponse(type)),
          WebDavFetchStatus.failed,
          reason: '$type must not be treated as an empty sync file',
        );
      }
    });

    test('non-Dio errors are errors', () {
      expect(
        classifyWebDavReadError(const SocketException('no route to host')),
        WebDavFetchStatus.failed,
      );
      expect(
        classifyWebDavReadError(Exception('boom')),
        WebDavFetchStatus.failed,
      );
      expect(
        classifyWebDavReadError(StateError('boom')),
        WebDavFetchStatus.failed,
      );
    });
  });

  group('parseWebDavProgressPayload', () {
    test('decodes a normal progress map', () {
      final bytes = utf8.encode(
        jsonEncode({
          'book-a': {'locator': '{"cfi":"a"}', 'timestamp': 1},
          'book-b': {'locator': '{"cfi":"b"}', 'timestamp': 2},
        }),
      );

      final parsed = parseWebDavProgressPayload(bytes);

      expect(parsed.keys, containsAll(['book-a', 'book-b']));
      expect(parsed['book-b']['timestamp'], 2);
    });

    test('an empty body is an empty progress map', () {
      expect(parseWebDavProgressPayload(const []), isEmpty);
      expect(parseWebDavProgressPayload(utf8.encode('   ')), isEmpty);
    });

    test('invalid JSON is corrupt, not empty', () {
      expect(
        () => parseWebDavProgressPayload(utf8.encode('{not json')),
        throwsA(isA<WebDavSyncException>()),
      );
    });

    test('valid JSON that is not an object is corrupt, not empty', () {
      expect(
        () => parseWebDavProgressPayload(utf8.encode('[1,2,3]')),
        throwsA(isA<WebDavSyncException>()),
      );
      expect(
        () => parseWebDavProgressPayload(utf8.encode('"a string"')),
        throwsA(isA<WebDavSyncException>()),
      );
      expect(
        () => parseWebDavProgressPayload(utf8.encode('42')),
        throwsA(isA<WebDavSyncException>()),
      );
      expect(
        () => parseWebDavProgressPayload(utf8.encode('null')),
        throwsA(isA<WebDavSyncException>()),
      );
    });

    test('invalid UTF-8 is corrupt, not empty', () {
      expect(
        () => parseWebDavProgressPayload(const [0xC3, 0x28]),
        throwsA(isA<WebDavSyncException>()),
      );
    });
  });

  group('buildProgressPayloadToWrite', () {
    Map<String, dynamic> existing() => {
      'other-book': {'locator': '{"cfi":"other"}', 'timestamp': 111},
    };

    test('merges into existing remote data without dropping other books', () {
      final payload = buildProgressPayloadToWrite(
        read: WebDavFetchResult.ok(existing()),
        bookUuid: 'this-book',
        locatorJson: '{"cfi":"here"}',
        timestamp: 222,
      );

      expect(payload, isNotNull);
      expect(payload!.keys, containsAll(['other-book', 'this-book']));
      expect(payload['other-book']['timestamp'], 111);
      expect(payload['this-book'], {
        'locator': '{"cfi":"here"}',
        'timestamp': 222,
      });
    });

    test('does not mutate the fetched map in place', () {
      final remote = existing();

      buildProgressPayloadToWrite(
        read: WebDavFetchResult.ok(remote),
        bookUuid: 'this-book',
        locatorJson: '{"cfi":"here"}',
        timestamp: 222,
      );

      expect(remote.keys, ['other-book']);
    });

    test('first run (not found) writes a fresh single-entry file', () {
      final payload = buildProgressPayloadToWrite(
        read: const WebDavFetchResult.notFound(),
        bookUuid: 'this-book',
        locatorJson: '{"cfi":"here"}',
        timestamp: 222,
      );

      expect(payload, {
        'this-book': {'locator': '{"cfi":"here"}', 'timestamp': 222},
      });
    });

    test('an existing but empty remote file writes a single entry', () {
      final payload = buildProgressPayloadToWrite(
        read: const WebDavFetchResult.ok({}),
        bookUuid: 'this-book',
        locatorJson: '{"cfi":"here"}',
        timestamp: 222,
      );

      expect(payload, {
        'this-book': {'locator': '{"cfi":"here"}', 'timestamp': 222},
      });
    });

    test('aborts the write when the read failed (the data-loss bug)', () {
      final payload = buildProgressPayloadToWrite(
        read: WebDavFetchResult.failed(
          _dioWithoutResponse(DioExceptionType.connectionTimeout),
        ),
        bookUuid: 'this-book',
        locatorJson: '{"cfi":"here"}',
        timestamp: 222,
      );

      expect(
        payload,
        isNull,
        reason: 'a failed read must never produce a write',
      );
    });

    test('aborts on expired auth rather than truncating the file', () {
      final read = WebDavFetchResult.failed(
        _dioWithStatus(HttpStatus.unauthorized),
      );

      expect(read.isRemoteStateKnown, isFalse);
      expect(
        buildProgressPayloadToWrite(
          read: read,
          bookUuid: 'this-book',
          locatorJson: '{"cfi":"here"}',
          timestamp: 222,
        ),
        isNull,
      );
    });

    test('aborts on a corrupt remote file rather than overwriting it', () {
      final read = WebDavFetchResult.failed(
        const WebDavSyncException('Sync file is not valid JSON'),
      );

      expect(
        buildProgressPayloadToWrite(
          read: read,
          bookUuid: 'this-book',
          locatorJson: '{"cfi":"here"}',
          timestamp: 222,
        ),
        isNull,
      );
    });
  });

  group('WebDavFetchResult.isRemoteStateKnown', () {
    test('only ok and notFound are safe to write after', () {
      expect(const WebDavFetchResult.ok({}).isRemoteStateKnown, isTrue);
      expect(const WebDavFetchResult.notFound().isRemoteStateKnown, isTrue);
      expect(
        WebDavFetchResult.failed(Exception('x')).isRemoteStateKnown,
        isFalse,
      );
    });
  });
}
