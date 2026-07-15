import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Wraps an inner (usually non-streaming) client so that a GET to the group's
/// `/feed/stream` returns a long-lived `text/event-stream` response, the way the
/// real server holds an SSE connection open.
///
/// The inner mock never sees the stream request, so its request counting and
/// one-shot bodies are untouched — a screen under test can subscribe to a live
/// feed that simply stays open and silent unless the test pushes something.
///
/// [push] a ride delta, or [pushRaw] arbitrary SSE bytes, to drive live updates;
/// [drop] closes the connection so the client's reconnect path can be exercised.
class FakeStreamClient extends http.BaseClient {
  FakeStreamClient(this._inner);

  final http.Client _inner;
  final List<StreamController<List<int>>> _connections = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/feed/stream')) {
      final controller = StreamController<List<int>>();
      _connections.add(controller);
      return http.StreamedResponse(
        controller.stream,
        200,
        headers: const {'content-type': 'text/event-stream'},
        request: request,
      );
    }
    return _inner.send(request);
  }

  /// Push a `ride` delta down every open stream, shaped exactly like the server's.
  void push(Map<String, dynamic> ride) {
    pushRaw('event: ride\ndata: ${jsonEncode({'ride': ride})}\n\n');
  }

  /// Push arbitrary SSE text (its own framing) down every open stream.
  void pushRaw(String sse) {
    final bytes = utf8.encode(sse);
    for (final c in _connections) {
      if (!c.isClosed) c.add(bytes);
    }
  }

  /// Close every open stream, simulating a dropped connection.
  void drop() {
    for (final c in _connections) {
      if (!c.isClosed) c.close();
    }
    _connections.clear();
  }

  @override
  void close() {
    drop();
    _inner.close();
  }
}
