import 'dart:async';

import 'models.dart';

/// One update pushed down the live feed stream.
///
/// The REST feed is the initial load and the source of truth; these events
/// layer the changes on top of it as they happen, so an open board updates
/// itself without polling.
sealed class FeedEvent {
  const FeedEvent();
}

/// A single ride changed — created, answered, or moved along a step. Carries the
/// whole ride as the feed now shows it, so the client applies it by replacing
/// (or inserting) that one ride, with no full re-fetch. See [Feed.withRide].
class RideChanged extends FeedEvent {
  const RideChanged(this.ride);
  final Ride ride;
}

/// "Refetch the whole board to converge." Sent after the stream reconnects
/// following a drop (the client may have missed deltas while it was gone) and
/// when the server signals a subscriber fell behind. The screen answers it with
/// an ordinary REST fetch, which is guaranteed to reflect the current truth.
class FeedResync extends FeedEvent {
  const FeedResync();
}

/// One parsed Server-Sent Event: its `event:` name and its concatenated `data:`.
class SseMessage {
  const SseMessage({required this.event, required this.data});
  final String event;
  final String data;
}

/// Parse a stream of already-split SSE lines into [SseMessage]s.
///
/// Follows the Server-Sent Events wire format: `field: value` lines accumulate
/// into an event, multiple `data:` lines join with newlines, a line beginning
/// with `:` is a comment (the keep-alive heartbeat is one), and a blank line
/// dispatches the event built so far. `id`/`retry` are accepted and ignored.
///
/// Split out as a top-level function so the parsing is unit-testable on its own,
/// without a socket.
Stream<SseMessage> parseServerSentEvents(Stream<String> lines) async* {
  var event = '';
  final data = <String>[];

  await for (final line in lines) {
    if (line.isEmpty) {
      // A blank line ends the current event. An event with neither a name nor
      // any data is just spacing between real events — nothing to dispatch.
      if (event.isNotEmpty || data.isNotEmpty) {
        yield SseMessage(
          event: event.isEmpty ? 'message' : event,
          data: data.join('\n'),
        );
      }
      event = '';
      data.clear();
      continue;
    }
    // Comments (and the ":\n" keep-alive) start with a colon and carry no field.
    if (line.startsWith(':')) continue;

    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    // A single leading space after the colon is part of the syntax, not the value.
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
      default:
        break; // id, retry, anything else: not needed here.
    }
  }
}

/// A self-healing live feed: it keeps a stream connection open, forwards the
/// deltas that come down it, and — after any drop — reconnects and asks the
/// screen to refetch so the board converges on the current state.
///
/// It is given a [connect] that opens one fresh [FeedEvent] stream (in
/// production, `ApiClient.streamFeed`); injecting it keeps the reconnect logic
/// testable without a socket. [retryDelay] paces reconnection attempts after a
/// drop.
class LiveFeed {
  LiveFeed({
    required this.connect,
    this.retryDelay = const Duration(seconds: 3),
  }) {
    _run();
  }

  /// Opens one fresh [FeedEvent] stream. Called again on every reconnect.
  final Stream<FeedEvent> Function() connect;
  final Duration retryDelay;

  final StreamController<FeedEvent> _out = StreamController<FeedEvent>();
  StreamSubscription<FeedEvent>? _sub;
  Timer? _retryTimer;
  bool _closed = false;
  bool _firstConnect = true;

  /// The merged stream of live events for the screen to listen to.
  Stream<FeedEvent> get events => _out.stream;

  /// Open a connection and forward its events; when it ends or errors, schedule
  /// a reconnect (unless we've been closed).
  void _run() {
    if (_closed) return;

    // A reconnection may have missed deltas while the connection was down, so
    // nudge the screen to refetch and converge. Not on the very first connect —
    // the screen has just done its initial REST load.
    if (!_firstConnect && !_out.isClosed) {
      _out.add(const FeedResync());
    }
    _firstConnect = false;

    _sub = connect().listen(
      (event) {
        if (!_out.isClosed) _out.add(event);
      },
      onError: (_) => _reconnectLater(),
      onDone: _reconnectLater,
      cancelOnError: true,
    );
  }

  void _reconnectLater() {
    _sub = null;
    if (_closed) return;
    _retryTimer = Timer(retryDelay, _run);
  }

  /// Stop for good: cancel the live connection and any pending reconnect, and
  /// close the outgoing stream. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    await _sub?.cancel();
    await _out.close();
  }
}
