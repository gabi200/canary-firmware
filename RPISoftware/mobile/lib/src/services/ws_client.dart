import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';

/// Live incident/check-in stream over WebSocket with auto-reconnect.
///
/// Emits decoded JSON maps (events of type "incident" / "checkin"). On a dropped
/// connection it reconnects with capped backoff; consumers stay subscribed.
/// [connection] says whether the socket is actually open.
class WsClient {
  WsClient({required this.baseUrl, required this.buildingId, required this.token});

  /// The hub's REST base (e.g. http://10.247.177.188:8000); the socket uses ws:// on it.
  final String baseUrl;
  final String buildingId;
  final String token;

  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  final _status = StreamController<bool>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retry;
  Timer? _ping;
  bool _closed = false;
  Duration _backoff = const Duration(seconds: 1);

  Stream<Map<String, dynamic>> get events => _controller.stream;

  /// true once the socket is open, false when it fails or drops (a retry follows).
  Stream<bool> get connection => _status.stream;

  void connect() {
    if (_closed) return;
    final uri = Uri.parse('${Config.wsBaseFor(baseUrl)}/api/v1/ws/incidents')
        .replace(queryParameters: {'building_id': buildingId, 'token': token});
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      // A refused or unreachable socket fails `ready` as well as the stream. The
      // stream's error schedules the retry; `ready` only reports the state (left
      // unhandled, every failed attempt was an uncaught error in the browser).
      channel.ready.then((_) {
        if (_closed || _channel != channel) return;
        _backoff = const Duration(seconds: 1);
        _status.add(true);
      }, onError: (Object _) {});
      // Three-Pi hub: the socket runs through the floating hub address. If the Pi behind it
      // dies, an idle socket never notices; a small frame every 25 s meets a reset from the Pi
      // that took the address over, which ends the stream and reconnects. The hub ignores it.
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 25), (_) {
        if (_channel != channel) return;
        try {
          channel.sink.add('ping');
        } catch (_) {
          // closed meanwhile: the stream's onDone/onError reconnects
        }
      });
      _sub = channel.stream.listen(
        (data) {
          _backoff = const Duration(seconds: 1);
          try {
            final map = jsonDecode(data as String) as Map<String, dynamic>;
            _controller.add(map);
          } catch (_) {
            // ignore malformed frame
          }
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _ping?.cancel();
    if (_closed) return;
    _status.add(false);
    _sub?.cancel();
    _channel = null;
    _retry?.cancel();
    _retry = Timer(_backoff, connect);
    _backoff = Duration(seconds: (_backoff.inSeconds * 2).clamp(1, 30));
  }

  Future<void> dispose() async {
    _closed = true;
    _retry?.cancel();
    _ping?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _controller.close();
    await _status.close();
  }
}
