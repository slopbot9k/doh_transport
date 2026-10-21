import 'dart:async';

import 'exceptions.dart';

/// A started request. Starting never throws: every failure completes [result]
/// with a [DohTransportException], and an unawaited [result] never raises an
/// uncaught error.
class DohTransportOperation<T> {
  final Future<T> result;

  /// Fails an unfinished operation and releases its work. Repeated calls are
  /// safe.
  final void Function() cancel;
  DohTransportOperation(this.result, this.cancel) {
    result.ignore();
  }

  /// The error is reported only to listeners of [result]; dropping it is safe.
  DohTransportOperation.failed(DohTransportException error)
      : this(Future<T>.error(error), _noop);
}

void _noop() {}

/// The body of an HTTP 200 response from a DoH resolver.
class DohHttpResponse {
  final List<int> body;

  /// Time the response spent in HTTP caches, from its `Age` header.
  final Duration age;
  DohHttpResponse(List<int> body, {this.age = Duration.zero})
      : body = List.unmodifiable(body) {
    if (age < Duration.zero) throw ArgumentError.value(age, 'age');
  }
}

/// Sends bounded HTTPS GET requests to a DoH resolver.
///
/// Only HTTP 200 bodies are delivered; every other status is a
/// [DohHttpStatusException]. Implementations deliver failures through
/// [DohTransportOperation.result] and make cancellation idempotent.
abstract interface class DohTransport {
  /// Requests [uri], sending [mediaType] as `Accept` and requiring it as the
  /// response `Content-Type`. The body is returned as received.
  DohTransportOperation<DohHttpResponse> start(Uri uri,
      {required String mediaType, required int maxResponseBytes});
}

/// Sends bounded RFC 8484 wire-format queries. Only HTTP 200 bodies are
/// delivered; every other status is a [DohHttpStatusException] failure.
abstract interface class DohWireTransport {
  DohTransportOperation<DohHttpResponse> startWire(Uri uri, List<int> query,
      {required int maxResponseBytes});
}

/// Whether [uri] is a usable HTTPS endpoint: no credentials or fragment, a
/// host, and a port that parses and fits 1-65535.
bool isUsableDohEndpoint(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  try {
    return uri.port >= 1 && uri.port <= 65535;
  } on FormatException {
    return false;
  }
}
