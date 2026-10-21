import 'dart:async';

import 'package:doh_transport/doh_transport_io.dart';
import 'package:test/test.dart';

import 'support/fake_http_client.dart';

void main() {
  final endpoint = Uri.https('resolver.example', '/dns-query');

  IoDohTransport transport(FakeDohHttpClient fake,
      {Duration timeout = const Duration(seconds: 1), int concurrent = 8}) {
    final result = IoDohTransport(
      httpClientFactory: fake.create,
      requestTimeout: timeout,
      maxConcurrentRequests: concurrent,
    );
    addTearDown(result.close);
    return result;
  }

  test('fake factory drives a padded wire exchange without sockets', () async {
    late List<int> sent;
    final fake = FakeDohHttpClient(reply: (_, body) {
      sent = body;
      return wireEcho(body);
    });
    final query = wireQuery(id: 0x1234);
    final response = await transport(fake)
        .startWire(endpoint, query, maxResponseBytes: 65535)
        .result;

    expect(fake.createdClients, 1);
    expect(fake.requests.single.method, 'POST');
    expect(sent.length, greaterThan(query.length));
    expect(sent.length % 128, 0);
    expect(sent.sublist(0, 2), isNot(u16(0x1234)));
    expect(response.body.sublist(0, 2), u16(0x1234));
    expect(fake.maxConnectionsPerHost, 1);
    expect(fake.autoUncompress, isFalse);
    expect(fake.userAgent, isNull);
    expect(fake.findProxy!(endpoint), 'DIRECT');
  });

  test('factory failures stay asynchronous and release the lane slot',
      () async {
    final fake = FakeDohHttpClient(reply: (_, body) => wireEcho(body));
    var attempts = 0;
    final t = IoDohTransport(
      httpClientFactory: (context) {
        if (attempts++ == 0) throw StateError('factory failed');
        return fake.create(context);
      },
      maxConcurrentRequests: 1,
    );
    addTearDown(t.close);

    late DohTransportOperation<DohHttpResponse> failed;
    expect(
      () => failed = t.startWire(
        endpoint,
        wireQuery(id: 1),
        maxResponseBytes: 65535,
      ),
      returnsNormally,
    );
    await expectLater(
        failed.result,
        throwsA(isA<DohConnectionException>()
            .having((error) => error.cause, 'cause', isA<StateError>())));

    final response = await t
        .startWire(endpoint, wireQuery(id: 2), maxResponseBytes: 65535)
        .result;
    expect(response.body.sublist(0, 2), u16(2));
    expect(attempts, 2);
  });

  test('rejects an oversized declared body', () async {
    final fake = FakeDohHttpClient(
      reply: (_, body) => wireEcho(body),
      scripts: const [FakeDohHttpScript(declaredContentLength: 65536)],
    );
    await expectLater(
      transport(fake)
          .startWire(endpoint, wireQuery(), maxResponseBytes: 65535)
          .result,
      throwsA(isA<DohResponseTooLargeException>()),
    );
  });

  test('rejects an oversized chunked body while streaming', () async {
    final fake = FakeDohHttpClient(
      reply: (_, __) => List<int>.filled(257, 0),
      scripts: const [
        FakeDohHttpScript(chunkSizes: [128, 129])
      ],
    );
    await expectLater(
      transport(fake)
          .startWire(endpoint, wireQuery(), maxResponseBytes: 256)
          .result,
      throwsA(isA<DohResponseTooLargeException>()),
    );
  });

  test('preserves HTTP status and parses Age', () async {
    final failed = FakeDohHttpClient(
      reply: (_, body) => wireEcho(body),
      scripts: const [FakeDohHttpScript(statusCode: 500)],
    );
    await expectLater(
      transport(failed)
          .startWire(endpoint, wireQuery(), maxResponseBytes: 65535)
          .result,
      throwsA(isA<DohHttpStatusException>()
          .having((error) => error.statusCode, 'statusCode', 500)),
    );

    final aged = FakeDohHttpClient(
      reply: (_, body) => wireEcho(body),
      scripts: const [FakeDohHttpScript(age: '17')],
    );
    final response = await transport(aged)
        .startWire(endpoint, wireQuery(), maxResponseBytes: 65535)
        .result;
    expect(response.age, const Duration(seconds: 17));
  });

  test('hung response reaches request timeout and is aborted', () async {
    final fake = FakeDohHttpClient(
      reply: (_, body) => wireEcho(body),
      scripts: const [FakeDohHttpScript(hang: true)],
    );
    await expectLater(
      transport(fake, timeout: const Duration(milliseconds: 20))
          .startWire(endpoint, wireQuery(), maxResponseBytes: 65535)
          .result,
      throwsA(isA<DohRequestTimeoutException>().having((error) => error.timeout,
          'timeout', const Duration(milliseconds: 20))),
    );
    expect(fake.aborts, 1);
    expect(fake.requests.single.aborted, isTrue);
  });

  test('cancelling one lane does not abort another lane', () async {
    final fake = FakeDohHttpClient(
      reply: (_, body) => wireEcho(body),
      scripts: const [
        FakeDohHttpScript(hang: true),
        FakeDohHttpScript(delay: Duration(milliseconds: 50)),
      ],
    );
    final t = transport(fake, concurrent: 2);
    final hung =
        t.startWire(endpoint, wireQuery(id: 1), maxResponseBytes: 65535);
    final other =
        t.startWire(endpoint, wireQuery(id: 2), maxResponseBytes: 65535);
    final failed =
        expectLater(hung.result, throwsA(isA<DohCancelledException>()));
    hung.cancel();
    await failed;
    expect((await other.result).body.sublist(0, 2), u16(2));
    expect(fake.createdClients, 2);
    expect(fake.aborts, 1);
  });

  test('dropped results of cancelled and failed starts raise no zone error',
      () async {
    final fake = FakeDohHttpClient(
      reply: (_, body) => wireEcho(body),
      scripts: const [FakeDohHttpScript(hang: true)],
    );
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final t = transport(fake);
      t.startWire(endpoint, wireQuery(), maxResponseBytes: 65535).cancel();
      t
          .startWire(endpoint.replace(scheme: 'http'), wireQuery(),
              maxResponseBytes: 65535)
          .cancel();
      t.startWire(endpoint, wireReply(), maxResponseBytes: 65535);
      t.startWire(endpoint, wireQuery(), maxResponseBytes: 65535);
      t.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }, (error, _) => errors.add(error));
    expect(errors, isEmpty);
    expect(fake.aborts, 2);
  });

  test('request timeout starts when a queued request is dispatched', () async {
    final fake = FakeDohHttpClient(
      reply: (_, body) => wireEcho(body),
      scripts: const [
        FakeDohHttpScript(hang: true),
        FakeDohHttpScript(delay: Duration(milliseconds: 50)),
      ],
    );
    final t = transport(fake,
        timeout: const Duration(milliseconds: 100), concurrent: 1);
    final hung = t.startWire(endpoint, wireQuery(id: 1), maxResponseBytes: 512);
    final queued =
        t.startWire(endpoint, wireQuery(id: 2), maxResponseBytes: 512);
    await expectLater(hung.result, throwsA(isA<DohRequestTimeoutException>()));
    expect((await queued.result).body.sublist(0, 2), u16(2));
  });

  test('supports overlapping in-flight requests', () async {
    final entered = Completer<void>();
    var replies = 0;
    final fake = FakeDohHttpClient(
      reply: (_, body) {
        replies++;
        if (replies == 2) entered.complete();
        return wireEcho(body);
      },
      scripts: const [
        FakeDohHttpScript(delay: Duration(milliseconds: 20)),
        FakeDohHttpScript(delay: Duration(milliseconds: 20)),
      ],
    );
    final t = transport(fake, concurrent: 2);
    final first =
        t.startWire(endpoint, wireQuery(id: 1), maxResponseBytes: 65535);
    final second =
        t.startWire(endpoint, wireQuery(id: 2), maxResponseBytes: 65535);
    await entered.future;
    final responses = await Future.wait([first.result, second.result]);

    expect(responses[0].body.sublist(0, 2), u16(1));
    expect(responses[1].body.sublist(0, 2), u16(2));
    expect(fake.createdClients, 2);
    expect(fake.requests, hasLength(2));
  });

  test('connection factory refuses a connection outside its request', () async {
    final fake = FakeDohHttpClient(reply: (_, body) => wireEcho(body));
    final t = transport(fake);
    await t
        .startWire(endpoint, wireQuery(id: 1), maxResponseBytes: 65535)
        .result;
    final factory = fake.connectionFactory!;

    // The lane is idle: no request owns it.
    expect(() => factory(endpoint, null, null),
        throwsA(isA<DohConnectionException>()));
    // Another origin never belongs to this lane.
    expect(() => factory(Uri.https('other.example', '/dns-query'), null, null),
        throwsA(isA<DohConnectionException>()));
  });
}
