import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';

/// Live incident/check-in stream over WebSocket with auto-reconnect.
///
/// Emits decoded JSON maps (events of type "incident" / "checkin"). On a dropped
/// connection it reconnects with capped backoff; consumers stay subscribed.
class WsClient {
  WsClient({required this.buildingId, required this.token});

  final String buildingId;
  final String token;

  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retry;
  bool _closed = false;
  Duration _backoff = const Duration(seconds: 1);

  Stream<Map<String, dynamic>> get events => _controller.stream;

  void connect() {
    if (_closed) return;
    final uri = Uri.parse('${Config.wsBase}/api/v1/ws/incidents?building_id=$buildingId&token=$token');
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
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
    if (_closed) return;
    _sub?.cancel();
    _channel = null;
    _retry?.cancel();
    _retry = Timer(_backoff, connect);
    _backoff = Duration(seconds: (_backoff.inSeconds * 2).clamp(1, 30));
  }

  Future<void> dispose() async {
    _closed = true;
    _retry?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _controller.close();
  }
}
