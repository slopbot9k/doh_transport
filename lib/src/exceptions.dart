/// Every deliberately reported failure from this package.
///
/// Callers can catch this root or switch on its final leaves. [cause] and
/// [causeStackTrace] keep a lower-layer error for diagnostics; [toString]
/// never prints them because they can contain endpoints.
sealed class DohTransportException implements Exception {
  final String message;
  final Object? cause;
  final StackTrace? causeStackTrace;
  const DohTransportException(this.message, {this.cause, this.causeStackTrace});

  @override
  String toString() => '$runtimeType: $message';
}

/// A caller-supplied wire query or request was unusable.
final class DohInvalidQueryException extends DohTransportException {
  const DohInvalidQueryException(super.message,
      {super.cause, super.causeStackTrace});
}

/// A response with the wrong media type or an encoding, or a wire reply whose
/// header or question is malformed, not a response, or truncated.
final class DohMalformedResponseException extends DohTransportException {
  const DohMalformedResponseException(super.message,
      {super.cause, super.causeStackTrace});
}

/// A response body larger than [limitBytes].
final class DohResponseTooLargeException extends DohTransportException {
  final int limitBytes;
  const DohResponseTooLargeException(super.message,
      {required this.limitBytes, super.cause, super.causeStackTrace});

  @override
  String toString() => '$runtimeType(limitBytes: $limitBytes): $message';
}

/// A response that does not answer the question asked.
final class DohQuestionMismatchException extends DohTransportException {
  const DohQuestionMismatchException(super.message,
      {super.cause, super.causeStackTrace});
}

/// The resolver answered with HTTP [statusCode] instead of 200.
final class DohHttpStatusException extends DohTransportException {
  final int statusCode;
  const DohHttpStatusException(super.message,
      {required this.statusCode, super.cause, super.causeStackTrace});

  @override
  String toString() => '$runtimeType(statusCode: $statusCode): $message';
}

/// A connection, TLS handshake, proxy, or HTTP exchange failed.
final class DohConnectionException extends DohTransportException {
  const DohConnectionException(super.message,
      {super.cause, super.causeStackTrace});
}

/// A request was rejected because the bounded queue was full.
final class DohQueueFullException extends DohTransportException {
  final int maxQueuedRequests;
  const DohQueueFullException(super.message,
      {required this.maxQueuedRequests, super.cause, super.causeStackTrace});

  @override
  String toString() =>
      '$runtimeType(maxQueuedRequests: $maxQueuedRequests): $message';
}

/// Why an operation was cancelled.
enum DohCancellationReason { caller, transportClosed }

/// An operation cancelled by its caller or by closing its transport.
final class DohCancelledException extends DohTransportException {
  final DohCancellationReason reason;
  const DohCancelledException(super.message,
      {this.reason = DohCancellationReason.caller,
      super.cause,
      super.causeStackTrace});

  @override
  String toString() => '$runtimeType(reason: ${reason.name}): $message';
}

/// An operation that reached its request deadline.
final class DohRequestTimeoutException extends DohTransportException {
  final Duration timeout;
  const DohRequestTimeoutException(super.message,
      {required this.timeout, super.cause, super.causeStackTrace});

  @override
  String toString() => '$runtimeType(timeout: $timeout): $message';
}

/// A connection, proxy negotiation, or TLS handshake reached its deadline.
final class DohConnectionTimeoutException extends DohTransportException {
  final Duration timeout;
  const DohConnectionTimeoutException(super.message,
      {required this.timeout, super.cause, super.causeStackTrace});

  @override
  String toString() => '$runtimeType(timeout: $timeout): $message';
}
