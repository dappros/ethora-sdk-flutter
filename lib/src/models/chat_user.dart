class ChatUser {
  const ChatUser({
    this.id,
    this.appId,
    this.firstName,
    this.lastName,
    this.email,
    this.username,
    this.walletAddress,
    this.xmppUsername,
    this.xmppPassword,
    this.token,
    this.refreshToken,
  });

  final String? id;
  final String? appId;
  final String? firstName;
  final String? lastName;
  final String? email;
  final String? username;
  final String? walletAddress;
  final String? xmppUsername;
  final String? xmppPassword;
  final String? token;
  final String? refreshToken;

  String get displayName {
    final fromName = [
      firstName,
      lastName,
    ].where((e) => (e ?? '').isNotEmpty).join(' ');
    if (fromName.isNotEmpty) {
      return fromName;
    }
    return username ?? email ?? walletAddress ?? id ?? 'Unknown';
  }

  ChatUser copyWith({
    String? id,
    String? appId,
    String? firstName,
    String? lastName,
    String? email,
    String? username,
    String? walletAddress,
    String? xmppUsername,
    String? xmppPassword,
    String? token,
    String? refreshToken,
  }) {
    return ChatUser(
      id: id ?? this.id,
      appId: appId ?? this.appId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      email: email ?? this.email,
      username: username ?? this.username,
      walletAddress: walletAddress ?? this.walletAddress,
      xmppUsername: xmppUsername ?? this.xmppUsername,
      xmppPassword: xmppPassword ?? this.xmppPassword,
      token: token ?? this.token,
      refreshToken: refreshToken ?? this.refreshToken,
    );
  }

  factory ChatUser.fromLoginResponse(Map<String, dynamic> json) {
    final user = (json['user'] as Map<String, dynamic>? ?? <String, dynamic>{});
    final defaultWallet =
        (user['defaultWallet'] as Map<String, dynamic>? ?? <String, dynamic>{});
    return ChatUser(
      id: user['_id']?.toString(),
      appId: user['appId']?.toString(),
      firstName: user['firstName']?.toString(),
      lastName: user['lastName']?.toString(),
      email: user['email']?.toString(),
      username: user['username']?.toString(),
      walletAddress:
          user['walletAddress']?.toString() ??
          defaultWallet['walletAddress']?.toString(),
      xmppUsername: user['xmppUsername']?.toString(),
      xmppPassword: user['xmppPassword']?.toString(),
      token: json['token']?.toString(),
      refreshToken: json['refreshToken']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'appId': appId,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'username': username,
      'walletAddress': walletAddress,
      'xmppUsername': xmppUsername,
      'xmppPassword': xmppPassword,
      'token': token,
      'refreshToken': refreshToken,
    };
  }

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      id: json['id']?.toString(),
      appId: json['appId']?.toString(),
      firstName: json['firstName']?.toString(),
      lastName: json['lastName']?.toString(),
      email: json['email']?.toString(),
      username: json['username']?.toString(),
      walletAddress: json['walletAddress']?.toString(),
      xmppUsername: json['xmppUsername']?.toString(),
      xmppPassword: json['xmppPassword']?.toString(),
      token: json['token']?.toString(),
      refreshToken: json['refreshToken']?.toString(),
    );
  }
}
