class AuthSession {
  const AuthSession({
    required this.token,
    required this.userId,
    required this.role,
    required this.username,
    required this.buildingId,
  });

  final String token;
  final String userId;
  final String role;
  final String username;
  final String buildingId;

  bool get isResident => role == 'resident';

  Map<String, dynamic> toJson() => {
        'token': token,
        'userId': userId,
        'role': role,
        'username': username,
        'buildingId': buildingId,
      };

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
        token: j['token'] as String,
        userId: j['userId'] as String,
        role: j['role'] as String,
        username: j['username'] as String,
        buildingId: j['buildingId'] as String,
      );

  AuthSession copyWith({String? buildingId}) => AuthSession(
        token: token,
        userId: userId,
        role: role,
        username: username,
        buildingId: buildingId ?? this.buildingId,
      );
}
