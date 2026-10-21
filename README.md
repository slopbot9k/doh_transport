# doh_transport

Bounded DNS-over-HTTPS transport for Dart: RFC 8484 wire-format POST and
plain GET exchanges, direct or through SOCKS5, with a typed failure hierarchy.

## Usage

```dart
import 'package:doh_transport/doh_transport_io.dart';

final transport = IoDohTransport();
try {
  final response = await transport
      .startWire(endpoint, query, maxResponseBytes: 65535)
      .result;
  // response.body is the DNS reply; response.age is its HTTP cache age.
} on DohTransportException catch (error) {
  print(error);
} finally {
  transport.close();
}
```

`doh_transport.dart` is platform-neutral: the `DohWireTransport` (POST) and
`DohTransport` (GET) interfaces, `DohTransportOperation`, `DohHttpResponse`,
`isUsableDohEndpoint`, and `DohTransportException` with its leaves.
`doh_transport_io.dart` adds `IoDohTransport` and `DohSocksProxy` on
`dart:io`.

## Trust model

`IoDohTransport` verifies the endpoint certificate, refuses redirects, bounds
response size and time, and never falls back from a configured proxy to a
direct connection. It accepts only HTTP 200 with the expected media type
(`application/dns-message` for wire queries, the caller's `mediaType` for GET)
and no content encoding. A wire reply must be an untruncated response with the
query's ID, opcode and question; its records are left to the caller's parser.
Nothing here validates DNSSEC: the resolver sees every query and may answer as
it likes. Without a proxy it also sees your address.

Every failure is a `DohTransportException` leaf delivered through
`DohTransportOperation.result`; `start` and `startWire` never throw. Only
HTTP 200 bodies are delivered; any other status is a `DohHttpStatusException`.
Leaves carry their status code, size limit, deadline, queue bound or
cancellation reason, and keep any lower-layer `cause` without printing it.

## Configuration

`IoDohTransport` options:

- `proxy`: a `DohSocksProxy` with a numeric address. Its `isolationToken`
  becomes SOCKS credentials, giving Tor stream isolation.
- `destination`: connect every request to this address, directly or through
  the proxy, so the endpoint host is never resolved. TLS still authenticates
  the URI host, so the address must serve its certificate.
- `reuseConnections`: share one connection per origin for wire queries. On by
  default without a proxy, off with one, where a shared connection lets the
  resolver link lookups. GET requests never share connections.
- `connectionTimeout` 5 s, covering TCP, SOCKS negotiation and the TLS
  handshake on every path; `requestTimeout` 30 s per operation once it leaves
  the queue; `idleTimeout` 5 s; `maxConcurrentRequests` 8;
  `maxQueuedRequests` 64; `padQueries` true (RFC 8467 padding of queries that
  end in an OPT record).
- `securityContext` for custom trust roots. `httpClientFactory` is for tests
  and bypasses the TLS and connection guarantees.

Wire query IDs are rewritten per connection and restored in the reply.

## Development

```
dart tool/check.dart                            # format, analyze, test, publish --dry-run
dart test -x integration                        # skip the loopback socket tests
DOH_LIVE_TESTS=1 dart test test/live_test.dart  # query public resolvers
```

## License

MIT; see `LICENSE`. `test/support/LICENSE` covers the test support files.
