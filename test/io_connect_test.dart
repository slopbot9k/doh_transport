@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:doh_transport/doh_transport_io.dart';
import 'package:test/test.dart';

import 'support/dns_wire.dart';
import 'support/tunnel_proxy.dart';

void main() {
  const timeout = Duration(milliseconds: 200);
  // Accepts TCP and never answers, so every TLS handshake stalls.
  late ServerSocket silent;
  late List<Socket> accepted;
  late List<Future<void>> peerClosed;
  setUp(() async {
    accepted = [];
    peerClosed = [];
    silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    silent.listen((socket) {
      accepted.add(socket);
      final closed = Completer<void>();
      void finish() {
        if (!closed.isCompleted) closed.complete();
      }

      socket.listen((_) {}, onError: (Object _) => finish(), onDone: finish);
      peerClosed.add(closed.future);
    });
  });
  tearDown(() async {
    for (final socket in accepted) {
      socket.destroy();
    }
    await silent.close();
  });

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  final paths = <String, Future<(IoDohTransport, String)> Function()>{
    'direct to a destination': () async => (
          IoDohTransport(
              destination: InternetAddress.loopbackIPv4,
              connectionTimeout: timeout),
          'resolver.example'
        ),
    'direct without a destination': () async =>
        (IoDohTransport(connectionTimeout: timeout), '127.0.0.1'),
    'through SOCKS': () async {
      final proxy = TunnelProxy(upstreamPort: silent.port);
      await proxy.start();
      addTearDown(proxy.close);
      return (
        IoDohTransport(
            proxy: DohSocksProxy(InternetAddress.loopbackIPv4, proxy.port),
            connectionTimeout: timeout),
        'resolver.example'
      );
    },
  };

  paths.forEach((name, create) {
    Future<DohTransportOperation<DohHttpResponse>> start() async {
      final (transport, host) = await create();
      addTearDown(transport.close);
      return transport.startWire(
          Uri.parse('https://$host:${silent.port}/dns-query'), wireQuery(),
          maxResponseBytes: 512);
    }

    test('$name: a stalled handshake reaches the connection deadline',
        () async {
      final started = DateTime.now();
      await expectLater(
          (await start()).result,
          throwsA(isA<DohConnectionTimeoutException>()
              .having((error) => error.timeout, 'timeout', timeout)));
      expect(DateTime.now().difference(started), lessThan(timeout * 5));
      expect(accepted, hasLength(1));
      await peerClosed.single.timeout(const Duration(seconds: 2));
    });

    test('$name: cancelling a stalled handshake closes the peer', () async {
      final operation = await start();
      final failed =
          expectLater(operation.result, throwsA(isA<DohCancelledException>()));
      await until(() => accepted.isNotEmpty);
      operation.cancel();
      await failed;
      await peerClosed.single.timeout(const Duration(seconds: 2));
    });
  });
}
