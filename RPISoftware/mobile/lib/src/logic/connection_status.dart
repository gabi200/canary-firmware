const connectionStaleAfter = Duration(seconds: 40);

/// Protocol frames used to prove liveness, not to update incident data.
bool isConnectionControlFrame(Map<String, dynamic> frame) =>
    frame['type'] == 'hello' || frame['type'] == 'ping';

bool isConnectionFresh(DateTime? lastMessageAt, DateTime now) {
  if (lastMessageAt == null) return false;
  return now.difference(lastMessageAt) < connectionStaleAfter;
}

String liveConnectionLabel({required DateTime? lastMessageAt, required DateTime now}) {
  if (lastMessageAt == null) return 'Live · updated just now';
  final seconds = now.difference(lastMessageAt).inSeconds.clamp(0, 1 << 31);
  if (seconds < 5) return 'Live · updated just now';
  return 'Live · updated $seconds s ago';
}
