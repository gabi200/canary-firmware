import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../logic/connection_status.dart';

/// Live incident/check-in stream over WebSocket with auto-reconnect.
///
/// Emits incident data frames only. Connection becomes true only after the server's
/// first frame, and becomes false before an internally scheduled reconnect.
class WsClient {
  WsClient({required this.buildingId, required this.token});

  final String buildingId;
  final String token;

  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  final _messages = StreamController<DateTime>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retry;
  bool _closed = false;
  Duration _backoff = const Duration(seconds: 1);

  Stream<Map<String, dynamic>> get events => _controller.stream;
  Stream<bool> get connection => _connection.stream;
  Stream<DateTime> get messages => _messages.stream;

  void connect() {
    if (_closed) return;
    final uri = Uri.parse('${Config.wsBase}/api/v1/ws/incidents?building_id=$buildingId&token=$token');
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _sub = channel.stream.listen(
        (data) {
          if (_channel != channel) return;
          _backoff = const Duration(seconds: 1);
          try {
            final map = jsonDecode(data as String) as Map<String, dynamic>;
            final receivedAt = DateTime.now();
            _messages.add(receivedAt);
            // The first frame proves the channel opened; later frames can restore a
            // controller that marked an unusually delayed link stale.
            _connection.add(true);
            if (!isConnectionControlFrame(map)) _controller.add(map);
          } catch (_) {
            // ignore malformed frame
          }
        },
        onDone: () => _scheduleReconnect(channel),
        onError: (_) => _scheduleReconnect(channel),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect([WebSocketChannel? channel]) {
    if (_closed) return;
    if (channel != null && _channel != channel) return;
    _connection.add(false);
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
    await _connection.close();
    await _messages.close();
  }
}
