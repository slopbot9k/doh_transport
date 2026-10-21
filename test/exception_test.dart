import 'dart:async';

import 'package:doh_transport/doh_transport.dart';
import 'package:test/test.dart';

void main() {
  final cause = StateError('resolver.example');
  final stack = StackTrace.current;
  final failures = <DohTransportException, String>{
    DohInvalidQueryException('invalid query',
        cause: cause,
        causeStackTrace: stack): 'DohInvalidQueryException: invalid query',
    DohMalformedResponseException('malformed response',
            cause: cause, causeStackTrace: stack):
        'DohMalformedResponseException: malformed response',
    DohResponseTooLargeException('too large',
            limitBytes: 512, cause: cause, causeStackTrace: stack):
        'DohResponseTooLargeException(limitBytes: 512): too large',
    DohQuestionMismatchException('wrong question',
        cause: cause,
        causeStackTrace: stack): 'DohQuestionMismatchException: wrong question',
    DohHttpStatusException('HTTP failure',
            statusCode: 503, cause: cause, causeStackTrace: stack):
        'DohHttpStatusException(statusCode: 503): HTTP failure',
    DohConnectionException('connection failure',
        cause: cause,
        causeStackTrace: stack): 'DohConnectionException: connection failure',
    DohQueueFullException('queue full',
            maxQueuedRequests: 4, cause: cause, causeStackTrace: stack):
        'DohQueueFullException(maxQueuedRequests: 4): queue full',
    DohRequestTimeoutException('request timeout',
            timeout: const Duration(seconds: 30),
            cause: cause,
            causeStackTrace: stack):
        'DohRequestTimeoutException(timeout: 0:00:30.000000): request timeout',
    DohConnectionTimeoutException('connection timeout',
            timeout: const Duration(seconds: 5),
            cause: cause,
            causeStackTrace: stack):
        'DohConnectionTimeoutException(timeout: 0:00:05.000000): '
            'connection timeout',
    DohCancelledException('cancelled',
            reason: DohCancellationReason.transportClosed,
            cause: cause,
            causeStackTrace: stack):
        'DohCancelledException(reason: transportClosed): cancelled',
  };

  test('every leaf has the sealed root and its own runtime type', () {
    expect(failures.keys.map((failure) => failure.runtimeType).toSet(),
        hasLength(failures.length));
  });

  test('the root keeps the cause and its stack without printing it', () {
    failures.forEach((failure, rendered) {
      expect(failure.cause, same(cause));
      expect(failure.causeStackTrace, same(stack));
      expect(failure.toString(), rendered);
      expect(failure.toString(), isNot(contains('resolver.example')));
    });
    const bare = DohConnectionException('no cause');
    expect(bare.cause, isNull);
    expect(bare.causeStackTrace, isNull);
  });

  test('structured fields keep status, limits, deadlines and reason', () {
    expect(const DohHttpStatusException('failed', statusCode: 429).statusCode,
        429);
    expect(
        const DohResponseTooLargeException('large', limitBytes: 65535)
            .limitBytes,
        65535);
    expect(
        const DohQueueFullException('full', maxQueuedRequests: 64)
            .maxQueuedRequests,
        64);
    expect(
        const DohRequestTimeoutException('late', timeout: Duration(seconds: 12))
            .timeout,
        const Duration(seconds: 12));
    expect(
        const DohConnectionTimeoutException('late',
                timeout: Duration(seconds: 3))
            .timeout,
        const Duration(seconds: 3));
    expect(const DohCancelledException('stopped').reason,
        DohCancellationReason.caller);
  });

  test('dropping any operation result cannot emit an uncaught zone error',
      () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      DohTransportOperation<void>(
          Future<void>.error(StateError('dropped')), () {});
      DohTransportOperation<void>.failed(
          const DohConnectionException('dropped'));
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => errors.add(error));

    expect(errors, isEmpty);
  });
}
