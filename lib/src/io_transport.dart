import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:socks_socket/socks_connection.dart';
import 'exceptions.dart';
import 'tls_connection.dart';
import 'transport.dart';
import 'wire.dart';

/// A SOCKS5 proxy, addressed numerically so no local DNS lookup is needed.
/// Use [SocksCredentials.isolation] for Tor stream isolation.
class SocksProxy {
  final InternetAddress host;
  final int port;
  final SocksCredentials? credentials;
  const SocksProxy(this.host, this.port, {this.credentials});
}

/// A `dart:io` HTTPS/1.1 DoH transport, direct or through SOCKS5.
///
/// It verifies the endpoint certificate, never follows redirects, never falls
/// back from a configured proxy to a direct connection, bounds bodies and
/// deadlines, and admits at most [maxConcurrentRequests] running plus
/// [maxQueuedRequests] waiting operations. Call [close] when done.
class IoDohTransport implements DohTransport, DohWireTransport {
  final SocksProxy? proxy;

  /// Connects every request to this address, directly or through the [proxy],
  /// so the endpoint host is never resolved locally or by the proxy. It applies
  /// to all endpoints used with this transport; TLS still verifies the
  /// requested host name.
  final InternetAddress? destination;
  final SecurityContext? securityContext;

  /// Creates each lane's HTTP client inside that lane's zone. For tests: the
  /// client it returns bypasses this transport's TLS and connection guarantees.
  final HttpClient Function(SecurityContext? context)? httpClientFactory;

  /// The deadline for each connection's TCP connect, SOCKS negotiation and
  /// TLS handshake.
  final Duration connectionTimeout;

  /// The deadline for each operation once it leaves the queue. A queued
  /// operation waits at most [maxQueuedRequests] / [maxConcurrentRequests]
  /// deadlines before its own starts.
  final Duration requestTimeout;
  final Duration idleTimeout;
  final int maxConcurrentRequests;
  final int maxQueuedRequests;

  /// Whether wire queries that end in an OPT record are padded to a multiple
  /// of 128 octets (RFC 8467).
  final bool padQueries;

  /// Whether wire queries to the same origin share connections. Off by
  /// default with a [proxy], where a shared connection lets the resolver link
  /// lookups. Wire IDs are rewritten per connection and restored in the
  /// response. GET requests never share connections.
  final bool reuseConnections;
  int _active = 0;
  bool _closed = false;
  final _waiting = Queue<_IoRequest>();
  final _running = <_IoRequest>{};
  final _idle = <_Lane>[];
  // Lanes fork from here: forking from Zone.current during a queued handoff
  // would parent each new lane on its predecessor and keep the chain alive.
  final _zone = Zone.current;
  final _random = Random.secure();
  IoDohTransport(
      {this.proxy,
      this.destination,
      this.securityContext,
      this.httpClientFactory,
      this.connectionTimeout = const Duration(seconds: 5),
      this.requestTimeout = const Duration(seconds: 30),
      this.idleTimeout = const Duration(seconds: 5),
      this.maxConcurrentRequests = 8,
      this.maxQueuedRequests = 64,
      this.padQueries = true,
      bool? reuseConnections})
      : reuseConnections = reuseConnections ?? proxy == null {
    if (destination?.type == InternetAddressType.unix) {
      throw ArgumentError('A numeric IP destination is required');
    }
    if (connectionTimeout <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        idleTimeout <= Duration.zero ||
        maxConcurrentRequests < 1 ||
        maxQueuedRequests < 0) {
      throw ArgumentError('Invalid transport limits');
    }
  }

  @override
  DnsOperation<DohHttpResponse> start(Uri uri,
      {required String mediaType, required int maxResponseBytes}) {
    final type = mediaType.toLowerCase();
    if (!_mediaType.hasMatch(type)) {
      return DnsOperation.failed(
          const DohInvalidQueryException('Expected a type/subtype media type'));
    }
    return _start(uri, type, maxResponseBytes);
  }

  @override
  DnsOperation<DohHttpResponse> startWire(Uri uri, List<int> query,
      {required int maxResponseBytes}) {
    final List<int> checked;
    try {
      checked =
          padQueries ? padDnsWireQuery(query) : checkedDnsWireQuery(query);
    } on DohTransportException catch (error) {
      return DnsOperation.failed(error);
    }
    return _start(uri, _dnsMessage, min(maxResponseBytes, 65535), checked);
  }

  /// Fails queued and running operations with [DohCancelledException], fails
  /// later starts the same way, and begins closing every connection. Socket
  /// teardown finishes asynchronously after this returns.
  Future<void> close() async {
    _closed = true;
    for (final request in [..._waiting, ..._running]) {
      request.cancel(DohCancellationReason.transportClosed);
    }
    for (final lane in [..._idle]) {
      _retire(lane);
    }
  }

  DnsOperation<DohHttpResponse> _start(
      Uri uri, String mediaType, int maxResponseBytes,
      [List<int>? query]) {
    // Before any request state exists: _origin throws on an unreadable port.
    if (!isUsableDohEndpoint(uri) || maxResponseBytes < 1) {
      return DnsOperation.failed(
          const DohInvalidQueryException('Expected a bounded HTTPS request'));
    }
    if (_closed) {
      return DnsOperation.failed(const DohCancelledException(
          'DNS transport closed',
          reason: DohCancellationReason.transportClosed));
    }
    if (_active >= maxConcurrentRequests &&
        _waiting.length >= maxQueuedRequests) {
      return DnsOperation.failed(DohQueueFullException(
          'DNS transport request queue is full',
          maxQueuedRequests: maxQueuedRequests));
    }
    final request = _IoRequest(this, uri, mediaType, maxResponseBytes, query);
    if (_active < maxConcurrentRequests) {
      _active++;
      _run(request);
    } else {
      _waiting.add(request);
    }
    return DnsOperation(request.result.future, request.cancel);
  }

  void _run(_IoRequest request) {
    request._startDeadline();
    _Lane? lane;
    final origin = _origin(request.uri);
    if (request.query != null) {
      for (var i = _idle.length - 1; i >= 0; i--) {
        final candidate = _idle[i];
        if (candidate.origin == origin && candidate.hasFreeWireIds) {
          _idle.removeAt(i);
          lane = candidate;
          break;
        }
      }
    }
    if (lane == null) {
      // One origin per client keeps live clients within the concurrency cap.
      if (_idle.isNotEmpty) _retire(_idle.last);
      try {
        lane = _newLane(origin);
      } catch (error, stack) {
        _active--;
        request._failBeforeRun(
            error is DohTransportException
                ? error
                : DohConnectionException('Resolver connection failed',
                    cause: error, causeStackTrace: stack),
            stack);
        return;
      }
    }
    lane.owner = request;
    request.lane = lane;
    if (request.query case final query?) {
      // A per-connection ID keeps a stale reply from answering the next
      // request.
      final id = lane.claimWireId(_random);
      request.sent = Uint8List.fromList(query)
        ..[0] = id >> 8
        ..[1] = id & 0xff;
    }
    _running.add(request);
    lane.zone.run(request.run);
  }

  _Lane _newLane(_Origin origin) {
    final lane = _Lane(origin);
    lane.zone = _zone.fork(specification:
        ZoneSpecification(handleUncaughtError: (_, __, ___, error, stack) {
      if (lane.owner case final owner?) {
        owner._finish(
            DohConnectionException('Resolver connection failed',
                cause: error, causeStackTrace: stack),
            stack);
      } else {
        _retire(lane);
      }
    }));
    lane.client = lane.zone.run(() {
      final client = (httpClientFactory ??
          (SecurityContext? context) => HttpClient(context: context))(
        securityContext,
      );
      try {
        client
          ..idleTimeout = idleTimeout
          ..maxConnectionsPerHost = 1
          ..autoUncompress = false
          ..userAgent = null
          ..findProxy = (_) => 'DIRECT';
        client.connectionFactory = (requested, _, __) async {
          final owner = lane.owner;
          if (owner == null ||
              owner._done ||
              _origin(requested) != lane.origin ||
              _origin(owner.uri) != lane.origin) {
            throw const DohConnectionException(
                'DNS connection refused outside its request');
          }
          final task = _connect(owner.uri);
          lane.tasks.add(task);
          task.socket.then((_) => lane.tasks.remove(task),
              onError: (Object _) => lane.tasks.remove(task));
          return task;
        };
      } catch (_) {
        try {
          client.close(force: true);
        } catch (_) {}
        rethrow;
      }
      return client;
    });
    return lane;
  }

  /// Opens a TLS connection for [uri] through the [proxy], or directly, to
  /// [destination] when set. Each path owns the [connectionTimeout] deadline
  /// and reports it as [DohConnectionTimeoutException].
  ConnectionTask<Socket> _connect(Uri uri) {
    final proxy = this.proxy;
    if (proxy == null) {
      return connectTls(destination ?? uri.host, uri.port,
          tlsHost: uri.host,
          context: securityContext,
          timeout: connectionTimeout);
    }
    final task = SocksConnection.start(
        proxyHost: proxy.host,
        proxyPort: proxy.port,
        targetHost: destination?.address ?? uri.host,
        targetPort: uri.port,
        tlsHost: uri.host,
        securityContext: securityContext,
        credentials: proxy.credentials,
        timeout: connectionTimeout);
    return ConnectionTask.fromSocket(
        task.socket.catchError(
            (Object error, StackTrace stack) =>
                throw DohConnectionTimeoutException(
                    'DNS connection deadline exceeded',
                    timeout: connectionTimeout,
                    cause: error,
                    causeStackTrace: stack),
            test: (error) =>
                error is SocksConnectException &&
                error.code == SocksConnectError.timedOut),
        task.cancel);
  }

  void _retire(_Lane lane) {
    if (lane.retired) return;
    lane.retired = true;
    lane.owner = null;
    _idle.remove(lane);
    try {
      lane.client.close(force: true);
    } catch (_) {}
    for (final task in [...lane.tasks]) {
      try {
        task.cancel();
      } catch (_) {}
    }
    lane.tasks.clear();
  }

  void _release(_IoRequest request, bool clean) {
    if (_waiting.remove(request)) return;
    _running.remove(request);
    final lane = request.lane!;
    if (clean &&
        request.query != null &&
        reuseConnections &&
        !_closed &&
        !lane.retired) {
      lane.owner = null;
      _idle.add(lane);
    } else {
      _retire(lane);
    }
    _active--;
    while (_waiting.isNotEmpty && _active < maxConcurrentRequests) {
      _active++;
      _run(_waiting.removeFirst());
    }
  }
}

const _dnsMessage = 'application/dns-message';

// A lower-case RFC 9110 type/subtype without parameters or wildcards.
final _mediaType = RegExp(r"^[!#$%&'+.^_`|~0-9a-z-]+/[!#$%&'+.^_`|~0-9a-z-]+$");

// RFC 9111 §5.1: use the first member of a list-valued or repeated Age, and
// ignore it if that member is not delta-seconds. Values beyond 2^31 saturate.
Duration _age(List<String>? values) {
  if (values == null || values.isEmpty) return Duration.zero;
  final first = values.first.split(',').first.trim();
  if (!RegExp(r'^[0-9]+$').hasMatch(first)) return Duration.zero;
  final digits = first.replaceFirst(RegExp(r'^0+'), '');
  final seconds = digits.length > 10 ? null : int.parse('0$digits');
  return Duration(seconds: min(seconds ?? 0x80000000, 0x80000000));
}

typedef _Origin = ({String scheme, String host, int port});

_Origin _origin(Uri uri) => (
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : 443,
    );

class _Lane {
  final _Origin origin;
  late final Zone zone;
  late final HttpClient client;
  final tasks = <ConnectionTask<Socket>>{};
  final _usedWireIds = Uint8List(8192);
  var _usedWireIdCount = 0;
  _IoRequest? owner;
  bool retired = false;

  _Lane(this.origin);

  // Retiring at half the ID space keeps random selection to ~2 draws.
  bool get hasFreeWireIds => _usedWireIdCount < 32768;

  bool _isUsed(int id) => _usedWireIds[id >> 3] & (1 << (id & 7)) != 0;

  /// Claims a random ID not yet used on this connection.
  int claimWireId(Random random) {
    while (true) {
      final id = random.nextInt(65536);
      if (_isUsed(id)) continue;
      _usedWireIds[id >> 3] |= 1 << (id & 7);
      _usedWireIdCount++;
      return id;
    }
  }
}

class _IoRequest {
  final IoDohTransport transport;
  final Uri uri;
  final String mediaType;
  final int limit;
  final List<int>? query;
  List<int>? sent;
  final result = Completer<DohHttpResponse>();
  _Lane? lane;
  Timer? _deadline;
  bool _done = false;
  _IoRequest(this.transport, this.uri, this.mediaType, this.limit, this.query) {
    result.future.ignore();
  }

  void _startDeadline() {
    _deadline = transport._zone.createTimer(
        transport.requestTimeout,
        () => _finish(DohRequestTimeoutException('DNS request timed out',
            timeout: transport.requestTimeout)));
  }

  void _finish(Object outcome, [StackTrace? stack]) {
    if (_done) return;
    _done = true;
    _deadline?.cancel();
    transport._release(this, outcome is DohHttpResponse);
    if (outcome is DohHttpResponse) {
      result.complete(outcome);
    } else {
      result.completeError(outcome, stack);
    }
  }

  void cancel([DohCancellationReason reason = DohCancellationReason.caller]) =>
      _finish(DohCancelledException('DNS request cancelled', reason: reason));

  void _failBeforeRun(Object error, StackTrace stack) {
    if (_done) return;
    _done = true;
    _deadline?.cancel();
    result.completeError(error, stack);
  }

  Future<void> run() async {
    if (_done) return;
    try {
      final request =
          await lane!.client.openUrl(query == null ? 'GET' : 'POST', uri);
      if (_done) {
        request.abort();
        return;
      }
      request.followRedirects = false;
      request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      request.headers.set(HttpHeaders.acceptHeader, mediaType);
      if (sent case final sent?) {
        request.headers.contentType = ContentType('application', 'dns-message');
        request.contentLength = sent.length;
        request.add(sent);
      }
      final response = await request.close();
      if (response.statusCode != 200) {
        throw DohHttpStatusException('Resolver HTTP request failed',
            statusCode: response.statusCode);
      }
      if (response.headers.contentType?.mimeType != mediaType) {
        throw const DohMalformedResponseException(
            'Unexpected DNS response media type');
      }
      if (response.headers.value(HttpHeaders.contentEncodingHeader)
          case final encoding? when encoding.toLowerCase() != 'identity') {
        throw const DohMalformedResponseException('Encoded DNS response');
      }
      if (response.contentLength > limit) {
        throw DohResponseTooLargeException('DNS body exceeds limit',
            limitBytes: limit);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > limit) {
          throw DohResponseTooLargeException('DNS body exceeds limit',
              limitBytes: limit);
        }
        bytes.add(chunk);
        if (_done) return;
      }
      final body = bytes.takeBytes();
      if (sent case final sent?) {
        validateDnsWireResponse(sent, body);
        body
          ..[0] = query![0]
          ..[1] = query![1];
      }
      _finish(DohHttpResponse(response.statusCode, body,
          age: _age(response.headers[HttpHeaders.ageHeader])));
    } catch (error, stack) {
      _finish(
          error is DohTransportException
              ? error
              : DohConnectionException('Resolver connection failed',
                  cause: error, causeStackTrace: stack),
          stack);
    }
  }
}
