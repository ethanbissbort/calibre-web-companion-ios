import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:calibre_web_companion/core/exceptions/cancellation_exception.dart';
import 'package:calibre_web_companion/core/services/download_manager.dart';

/// Deterministic clock for the throttle tests.
class _FakeClock {
  DateTime _now = DateTime.utc(2024, 1, 1);

  DateTime call() => _now;

  void advance(Duration d) => _now = _now.add(d);
}

List<int> _chunk(int length, int value) => List<int>.filled(length, value);

void main() {
  group('checkDownloadSize', () {
    test('matching byte counts are ok', () {
      expect(
        checkDownloadSize(receivedBytes: 1024, contentLength: 1024),
        DownloadSizeCheck.ok,
      );
    });

    test('fewer bytes than announced is a truncated transfer', () {
      expect(
        checkDownloadSize(receivedBytes: 512, contentLength: 1024),
        DownloadSizeCheck.truncated,
      );
    });

    test('more bytes than announced is an overrun', () {
      expect(
        checkDownloadSize(receivedBytes: 2048, contentLength: 1024),
        DownloadSizeCheck.overrun,
      );
    });

    test('a missing Content-Length is not an error', () {
      expect(
        checkDownloadSize(receivedBytes: 1024, contentLength: -1),
        DownloadSizeCheck.unknownLength,
      );
      expect(
        checkDownloadSize(receivedBytes: 1024, contentLength: 0),
        DownloadSizeCheck.unknownLength,
      );
    });

    test('an empty body is always a failure, announced or not', () {
      expect(
        checkDownloadSize(receivedBytes: 0, contentLength: -1),
        DownloadSizeCheck.empty,
      );
      expect(
        checkDownloadSize(receivedBytes: 0, contentLength: 1024),
        DownloadSizeCheck.empty,
      );
    });

    test('only truncated and empty transfers are unusable', () {
      expect(DownloadSizeCheck.ok.isUsable, isTrue);
      expect(DownloadSizeCheck.unknownLength.isUsable, isTrue);
      // Tolerated: a proxy that rewrites the body without fixing the header.
      expect(DownloadSizeCheck.overrun.isUsable, isTrue);
      expect(DownloadSizeCheck.truncated.isUsable, isFalse);
      expect(DownloadSizeCheck.empty.isUsable, isFalse);
    });

    test('the truncation message names both counts', () {
      final message = downloadSizeMessage(
        DownloadSizeCheck.truncated,
        receivedBytes: 512,
        contentLength: 1024,
      );
      expect(message, contains('512'));
      expect(message, contains('1024'));
    });
  });

  group('isContentLengthComparable', () {
    test('no content-encoding header means the length is comparable', () {
      expect(isContentLengthComparable(const {}), isTrue);
      expect(
        isContentLengthComparable(const {'content-type': 'application/epub'}),
        isTrue,
      );
    });

    test('identity encoding is comparable', () {
      expect(
        isContentLengthComparable(const {'content-encoding': 'identity'}),
        isTrue,
      );
      expect(
        isContentLengthComparable(const {'content-encoding': '  '}),
        isTrue,
      );
    });

    test('a compressed body makes Content-Length incomparable', () {
      expect(
        isContentLengthComparable(const {'content-encoding': 'gzip'}),
        isFalse,
      );
      expect(
        isContentLengthComparable(const {'Content-Encoding': 'GZIP'}),
        isFalse,
      );
      expect(
        isContentLengthComparable(const {'content-encoding': 'br'}),
        isFalse,
      );
    });
  });

  group('DownloadCancellationToken', () {
    test('starts uncancelled and does not throw', () {
      final token = DownloadCancellationToken();
      expect(token.isCancelled, isFalse);
      expect(token.throwIfCancelled, returnsNormally);
    });

    test('cancel is sticky and throws a CancellationException', () {
      final token = DownloadCancellationToken();
      token.cancel('user tapped cancel');

      expect(token.isCancelled, isTrue);
      expect(token.reason, 'user tapped cancel');
      expect(
        token.throwIfCancelled,
        throwsA(
          isA<CancellationException>().having(
            (e) => e.message,
            'message',
            'user tapped cancel',
          ),
        ),
      );
    });

    test('the first reason wins and repeated cancels are ignored', () {
      final token = DownloadCancellationToken();
      token.cancel('first');
      token.cancel('second');

      expect(token.reason, 'first');
      expect(token.isCancelled, isTrue);
    });

    test('cancelling without a reason keeps the default message', () {
      final token = DownloadCancellationToken();
      token.cancel();
      expect(token.reason, DownloadCancellationToken.defaultReason);
    });
  });

  group('DownloadProgressThrottle', () {
    test('the first update always passes', () {
      final throttle = DownloadProgressThrottle(clock: _FakeClock().call);
      expect(throttle.shouldEmit(0), isTrue);
    });

    test('drops updates inside the interval window', () {
      final clock = _FakeClock();
      final throttle = DownloadProgressThrottle(clock: clock.call);

      expect(throttle.shouldEmit(1), isTrue);
      clock.advance(const Duration(milliseconds: 10));
      expect(throttle.shouldEmit(2), isFalse);
      expect(throttle.shouldEmit(3), isFalse);
      expect(throttle.shouldEmit(4), isFalse);
      expect(throttle.lastPercent, 1);
    });

    test('lets an update through once the interval has elapsed', () {
      final clock = _FakeClock();
      final throttle = DownloadProgressThrottle(clock: clock.call);

      expect(throttle.shouldEmit(1), isTrue);
      clock.advance(const Duration(milliseconds: 250));
      expect(throttle.shouldEmit(7), isTrue);
      expect(throttle.lastPercent, 7);
    });

    test('an unchanged percentage is never re-emitted', () {
      final clock = _FakeClock();
      final throttle = DownloadProgressThrottle(clock: clock.call);

      expect(throttle.shouldEmit(42), isTrue);
      clock.advance(const Duration(seconds: 5));
      expect(throttle.shouldEmit(42), isFalse);
    });

    test('completion is never dropped, however soon it arrives', () {
      final clock = _FakeClock();
      final throttle = DownloadProgressThrottle(clock: clock.call);

      expect(throttle.shouldEmit(3), isTrue);
      clock.advance(const Duration(milliseconds: 1));
      expect(throttle.shouldEmit(100), isTrue);
    });

    test('caps a per-chunk flood to a handful of updates', () {
      final clock = _FakeClock();
      final throttle = DownloadProgressThrottle(clock: clock.call);

      var emitted = 0;
      // 1000 chunks arriving over one second of wall clock time.
      for (var i = 0; i <= 1000; i++) {
        if (throttle.shouldEmit((i / 10).round())) emitted++;
        clock.advance(const Duration(milliseconds: 1));
      }

      // ~1s / 250ms plus the first update and the terminal 100%.
      expect(emitted, lessThanOrEqualTo(6));
      expect(throttle.lastPercent, 100);
    });

    test('reset makes the next update pass unconditionally', () {
      final clock = _FakeClock();
      final throttle = DownloadProgressThrottle(clock: clock.call);

      expect(throttle.shouldEmit(10), isTrue);
      expect(throttle.shouldEmit(11), isFalse);
      throttle.reset();
      expect(throttle.shouldEmit(11), isTrue);
    });

    test('force bypasses both gates', () {
      final clock = _FakeClock();
      final throttle = DownloadProgressThrottle(clock: clock.call);

      expect(throttle.shouldEmit(10), isTrue);
      expect(throttle.shouldEmit(11, force: true), isTrue);
    });
  });

  group('pumpDownloadStream', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cwc_pump_test');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    File partFile(String name) => File('${tempDir.path}/$name.part');

    test('writes every byte to the sink and reports the total', () async {
      final file = partFile('complete');
      final sink = file.openWrite();

      final received = await pumpDownloadStream(
        source: Stream.fromIterable([
          _chunk(10, 1),
          _chunk(10, 2),
          _chunk(5, 3),
        ]),
        sink: sink,
        expectedLength: 25,
      );
      await sink.close();

      expect(received, 25);
      expect(file.lengthSync(), 25);
      expect(file.readAsBytesSync().first, 1);
      expect(file.readAsBytesSync().last, 3);
    });

    test('reports progress as a percentage of the announced length', () async {
      final file = partFile('progress');
      final sink = file.openWrite();
      final progress = <int>[];

      await pumpDownloadStream(
        source: Stream.fromIterable([
          _chunk(25, 1),
          _chunk(25, 1),
          _chunk(50, 1),
        ]),
        sink: sink,
        expectedLength: 100,
        onProgress: progress.add,
      );
      await sink.close();

      expect(progress, [25, 50, 100]);
    });

    test('stays silent when the server announced no length', () async {
      final file = partFile('no_length');
      final sink = file.openWrite();
      final progress = <int>[];

      final received = await pumpDownloadStream(
        source: Stream.fromIterable([_chunk(8, 1), _chunk(8, 1)]),
        sink: sink,
        expectedLength: -1,
        onProgress: progress.add,
      );
      await sink.close();

      expect(received, 16);
      expect(progress, isEmpty);
    });

    test('flushing mid-stream does not lose or duplicate bytes', () async {
      final file = partFile('flushed');
      final sink = file.openWrite();

      final received = await pumpDownloadStream(
        source: Stream.fromIterable(List.generate(20, (_) => _chunk(16, 7))),
        sink: sink,
        expectedLength: 320,
        // Force a flush after (almost) every chunk.
        flushEvery: 8,
      );
      await sink.close();

      expect(received, 320);
      expect(file.lengthSync(), 320);
      expect(file.readAsBytesSync().every((b) => b == 7), isTrue);
    });

    test('a token cancelled up front aborts before any byte is read', () async {
      final file = partFile('pre_cancelled');
      final sink = file.openWrite();
      final token = DownloadCancellationToken()..cancel('cancelled early');

      var chunksPulled = 0;
      Stream<List<int>> source() async* {
        chunksPulled++;
        yield _chunk(10, 1);
      }

      await expectLater(
        pumpDownloadStream(source: source(), sink: sink, cancelToken: token),
        throwsA(isA<CancellationException>()),
      );
      await sink.close();

      expect(chunksPulled, 0);
      expect(file.lengthSync(), 0);
    });

    test('cancelling mid-stream stops after the current chunk', () async {
      final file = partFile('mid_cancel');
      final sink = file.openWrite();
      final token = DownloadCancellationToken();
      final progress = <int>[];

      await expectLater(
        pumpDownloadStream(
          source: Stream.fromIterable([
            _chunk(10, 1),
            _chunk(10, 2),
            _chunk(10, 3),
          ]),
          sink: sink,
          expectedLength: 30,
          onProgress: (percent) {
            progress.add(percent);
            token.cancel('user tapped cancel');
          },
          cancelToken: token,
        ),
        throwsA(
          isA<CancellationException>().having(
            (e) => e.message,
            'message',
            'user tapped cancel',
          ),
        ),
      );
      await sink.close();

      // Only the first chunk made it; the rest of the transfer was aborted.
      expect(progress, [33]);
      expect(file.lengthSync(), 10);
    });

    test('a stream error propagates to the caller', () async {
      final file = partFile('stream_error');
      final sink = file.openWrite();

      Stream<List<int>> source() async* {
        yield _chunk(10, 1);
        throw const SocketException('connection reset');
      }

      await expectLater(
        pumpDownloadStream(source: source(), sink: sink),
        throwsA(isA<SocketException>()),
      );
      await sink.close();
    });

    test('a truncated transfer is detected after the pump finishes', () async {
      final file = partFile('truncated');
      final sink = file.openWrite();

      // The server promised 100 bytes but the connection dropped after 30.
      final received = await pumpDownloadStream(
        source: Stream.fromIterable([_chunk(10, 1), _chunk(20, 1)]),
        sink: sink,
        expectedLength: 100,
      );
      await sink.close();

      expect(received, 30);
      expect(
        checkDownloadSize(receivedBytes: received, contentLength: 100),
        DownloadSizeCheck.truncated,
      );
    });
  });
}
