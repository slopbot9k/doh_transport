import 'dart:io';

import 'package:doh_transport/doh_transport_io.dart';
import 'package:test/test.dart';

import 'support/dns_wire.dart';

final skip = Platform.environment['DOH_LIVE_TESTS'] == '1'
    ? null
    : 'Set DOH_LIVE_TESTS=1 to query public resolvers';

List<int> dnssecQuery(String name, int type) => [
      ...wireHeader(id: 0, flags: 0x0110, ar: 1),
      ...wireQuestion(wireName(name), type: type),
      ...wireOpt(options: [0, 8, 0, 4, 0, 1, 0, 0]),
    ];

void main() {
  for (final endpoint in [
    Uri.https('dns.google', '/dns-query'),
    Uri.https('cloudflare-dns.com', '/dns-query'),
  ]) {
    for (final (name, type) in [
      ('getmonero.org', 16),
      ('.', 48),
      ('no-such-label-8484.getmonero.org', 16),
    ]) {
      test('${endpoint.host} wire $name/$type', () async {
        final transport = IoDohTransport();
        addTearDown(transport.close);
        final response = await transport
            .startWire(endpoint, dnssecQuery(name, type),
                maxResponseBytes: 65535)
            .result;
        expect(response.body, isNotEmpty);
      }, skip: skip);
    }
  }
  test('dns.google wire through a fixed destination without local DNS',
      () async {
    final transport = IoDohTransport(destination: InternetAddress('8.8.8.8'));
    addTearDown(transport.close);
    final response = await transport
        .startWire(Uri.https('dns.google', '/dns-query'),
            dnssecQuery('getmonero.org', 16),
            maxResponseBytes: 65535)
        .result;
    expect(response.body, isNotEmpty);
  }, skip: skip);
}
