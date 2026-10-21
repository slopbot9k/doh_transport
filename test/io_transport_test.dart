@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:doh_transport/doh_transport_io.dart';
import 'package:test/test.dart';
import 'support/dns_wire.dart';
import 'support/test_pki.dart';
import 'support/tunnel_proxy.dart';

// RFC 8484 GET: the transport checks only the media type, not the body.
const mediaType = 'application/dns-message';
final dnsMessage = ContentType('application', 'dns-message');

void main() {
  late HttpServer server;
  late SecurityContext trust;
  late TestPki pki;
  setUpAll(() => pki = TestPki.generate());
  setUp(() async {
    trust = pki.clientContext();
    server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, pki.serverContext());
  });
  tearDown(() => server.close(force: true));
  final dns = base64Url.encode(wireQuery()).replaceAll('=', '');
  Uri endpoint() => Uri.parse('https://localhost:${server.port}/dns-query')
      .replace(queryParameters: {'dns': dns});
  DohTransportOperation<DohHttpResponse> get(IoDohTransport transport,
          {String type = mediaType, int maxResponseBytes = 65536}) =>
      transport.start(endpoint(),
          mediaType: type, maxResponseBytes: maxResponseBytes);

  for (final proxied in [false, true]) {
    test('authenticated GET over ${proxied ? 'SOCKS' : 'direct'} HTTPS',
        () async {
      var requests = 0;
      server.listen((request) {
        requests++;
        expect(request.method, 'GET');
        expect(request.uri.queryParameters['dns'], dns);
        expect(request.headers.value('accept'), mediaType);
        request.response.headers.contentType = dnsMessage;
        request.response.add(wireReply());
        request.response.close();
      });
      final proxy = TunnelProxy(upstreamPort: server.port, fragmented: true);
      if (proxied) {
        await proxy.start();
        addTearDown(proxy.close);
      }
      final transport = IoDohTransport(
          securityContext: trust,
          proxy: proxied
              ? DohSocksProxy(InternetAddress.loopbackIPv4, proxy.port)
              : null,
          destination: proxied ? InternetAddress('8.8.8.8') : null);
      final response = await get(transport).result;
      expect(response.body, wireReply(), reason: 'returned as received');
      expect(requests, 1);
      if (proxied) {
        expect(proxy.target, '8.8.8.8');
        transport.close();
        await proxy.disconnected.future.timeout(const Duration(seconds: 2));
      }
    });
  }
  test('a rejected required proxy never falls back to reachable direct HTTPS',
      () async {
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response.close();
    });
    final proxy = TunnelProxy(replyCode: 5);
    await proxy.start();
    addTearDown(proxy.close);
    final transport = IoDohTransport(
        securityContext: trust,
        proxy: DohSocksProxy(InternetAddress.loopbackIPv4, proxy.port));
    await expectLater(
        get(transport).result, throwsA(isA<DohConnectionException>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 0);
    expect(proxy.connections, 1);
  });
  test('HTTPS identity must be trusted', () async {
    server.listen((r) => r.response.close(), onError: (Object _) {});
    await expectLater(
        get(IoDohTransport()).result, throwsA(isA<DohConnectionException>()));
  });
  test('redirects never produce a second request', () async {
    var requests = 0;
    server.listen((r) {
      requests++;
      r.response.statusCode = 302;
      r.response.headers
          .set('location', endpoint().replace(path: '/redirected').toString());
      r.response.close();
    });
    await expectLater(
        get(IoDohTransport(securityContext: trust)).result,
        throwsA(isA<DohHttpStatusException>()
            .having((error) => error.statusCode, 'statusCode', 302)));
    expect(requests, 1);
  });
  test('streaming response size limit aborts before parsing', () async {
    server.listen((r) {
      r.response.headers.contentType = dnsMessage;
      r.response.write('x' * 129);
      r.response.close();
    });
    await expectLater(
        get(IoDohTransport(securityContext: trust), maxResponseBytes: 128)
            .result,
        throwsA(isA<DohResponseTooLargeException>()));
  });
  for (final cancel in [false, true]) {
    test('${cancel ? 'cancel' : 'timeout'} destroys stalled response transport',
        () async {
      final sent = Completer<void>();
      server.listen((r) async {
        r.response.headers.contentType = dnsMessage;
        r.response.write('x');
        await r.response.flush();
        if (!sent.isCompleted) sent.complete();
      });
      final proxy = TunnelProxy(upstreamPort: server.port);
      await proxy.start();
      addTearDown(proxy.close);
      final transport = IoDohTransport(
          securityContext: trust,
          requestTimeout: const Duration(milliseconds: 300),
          proxy: DohSocksProxy(InternetAddress.loopbackIPv4, proxy.port));
      final operation = get(transport);
      final failed = expectLater(
          operation.result,
          throwsA(cancel
              ? isA<DohCancelledException>()
              : isA<DohRequestTimeoutException>()));
      await sent.future;
      if (cancel) operation.cancel();
      await failed;
      await proxy.disconnected.future.timeout(const Duration(seconds: 2));
    });
  }
  test('generated test certificate is a short-lived serverAuth leaf', () async {
    server.listen((r) => r.response.close());
    final socket =
        await SecureSocket.connect('localhost', server.port, context: trust);
    final leaf = socket.peerCertificate!;
    socket.destroy();
    final now = DateTime.now();
    expect(leaf.issuer, contains('doh_resolver test CA'));
    expect(leaf.subject, isNot(leaf.issuer));
    expect(leaf.startValidity.isBefore(now), isTrue);
    expect(leaf.endValidity.difference(leaf.startValidity).inDays,
        lessThanOrEqualTo(31));
    await expectLater(
        SecureSocket.connect('localhost', server.port,
            context: TestPki.generate().clientContext()),
        throwsA(isA<HandshakeException>()));
  });
  test('requests identity encoding without a client fingerprint', () async {
    server.listen((r) {
      expect(r.headers[HttpHeaders.acceptEncodingHeader], isNull);
      expect(r.headers[HttpHeaders.userAgentHeader], isNull);
      r.response.headers.contentType = dnsMessage;
      r.response.add(wireReply());
      r.response.close();
    });
    final result = await get(IoDohTransport(securityContext: trust)).result;
    expect(result.body, isNotEmpty);
  });
  for (final (header, seconds) in [
    (null, 0),
    ('250', 250),
    (' 7 ', 7),
    ('000000000001', 1),
    ('00000000000000000000', 0),
    ('2147483648', 0x80000000),
    ('99999999999', 0x80000000),
    ('000099999999999', 0x80000000),
    ('250, 0', 250),
    ('5,abc', 5),
    (', 5', 0),
    ('-5', 0),
    ('1.5', 0),
    ('abc', 0),
  ]) {
    test('reports HTTP Age header $header as $seconds seconds', () async {
      server.listen((r) {
        r.response.headers.contentType = dnsMessage;
        if (header != null) {
          r.response.headers.set(HttpHeaders.ageHeader, header);
        }
        r.response.add(wireReply());
        r.response.close();
      });
      final response = await get(IoDohTransport(securityContext: trust)).result;
      expect(response.age, Duration(seconds: seconds));
    });
  }
  test('uses the first of repeated HTTP Age headers', () async {
    server.listen((r) {
      r.response.headers
        ..contentType = dnsMessage
        ..add(HttpHeaders.ageHeader, '250')
        ..add(HttpHeaders.ageHeader, '0');
      r.response.add(wireReply());
      r.response.close();
    });
    final response = await get(IoDohTransport(securityContext: trust)).result;
    expect(response.age, const Duration(seconds: 250));
  });
  test('sends the requested media type and requires it back', () async {
    final served = ['application/dns-json; charset=utf-8', 'application/json'];
    server.listen((r) {
      expect(r.headers.value('accept'), 'application/dns-json');
      r.response.headers.contentType = ContentType.parse(served.removeAt(0));
      r.response.write('{}');
      r.response.close();
    });
    final transport = IoDohTransport(securityContext: trust);
    addTearDown(transport.close);
    final response = await get(transport, type: 'Application/DNS-JSON').result;
    expect(utf8.decode(response.body), '{}');
    await expectLater(get(transport, type: 'application/dns-json').result,
        throwsA(isA<DohMalformedResponseException>()));
  });
  for (final (type, encoding) in [
    (null, null),
    (ContentType.text, null),
    (ContentType.html, null),
    (ContentType.json, null),
    (dnsMessage, 'gzip'),
  ]) {
    test('rejects a GET body typed $type encoded $encoding', () async {
      server.listen((r) {
        if (type != null) r.response.headers.contentType = type;
        if (encoding != null) {
          r.response.headers.set(HttpHeaders.contentEncodingHeader, encoding);
        }
        r.response.add(wireReply());
        r.response.close();
      });
      await expectLater(get(IoDohTransport(securityContext: trust)).result,
          throwsA(isA<DohMalformedResponseException>()));
    });
  }
}
