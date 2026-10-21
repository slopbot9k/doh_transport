import 'dart:io';

import 'package:doh_transport/doh_transport_io.dart';

Future<void> main() async {
  // A TXT query for openalias.org: header with RD set, then one question.
  final query = <int>[
    0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, //
    9, ...'openalias'.codeUnits, 3, ...'org'.codeUnits, 0, //
    0, 16, 0, 1,
  ];
  final transport = IoDohTransport(destination: InternetAddress('8.8.8.8'));
  try {
    final response = await transport
        .startWire(Uri.parse('https://dns.google/dns-query'), query,
            maxResponseBytes: 65535)
        .result;
    print('Reply: ${response.body.length} bytes');
  } on DohTransportException catch (error) {
    print(error);
  } finally {
    transport.close();
  }
}
