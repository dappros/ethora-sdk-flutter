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
    this.photoUrl,
    this.fileToken,
    this.appLanguage,
    this.chatLanguage,
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
  final String? photoUrl;

  /// Token appended as `ft` to secure media URLs (login/refresh response).
  final String? fileToken;

  /// Interface language of the account (BCP-47, e.g. "fr-CA"). Written by
  /// `PUT /v1/users {appLanguage}`.
  final String? appLanguage;

  /// Language incoming messages are translated into (BCP-47).
  final String? chatLanguage;

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
    String? photoUrl,
    String? fileToken,
    String? appLanguage,
    String? chatLanguage,
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
      photoUrl: photoUrl ?? this.photoUrl,
      fileToken: fileToken ?? this.fileToken,
      appLanguage: appLanguage ?? this.appLanguage,
      chatLanguage: chatLanguage ?? this.chatLanguage,
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
      walletAddress: user['walletAddress']?.toString() ??
          defaultWallet['walletAddress']?.toString(),
      xmppUsername: user['xmppUsername']?.toString(),
      xmppPassword: user['xmppPassword']?.toString(),
      token: json['token']?.toString(),
      refreshToken: json['refreshToken']?.toString(),
      photoUrl: user['profileImage']?.toString(),
      fileToken: json['fileToken']?.toString(),
      appLanguage: _nonEmpty(user['appLanguage']),
      chatLanguage: _nonEmpty(user['chatLanguage']),
    );
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// JSON without secrets (xmppPassword, token, refreshToken, fileToken).
  /// Secrets are kept in secure storage by [ChatComponentStore].
  Map<String, dynamic> toPublicJson() {
    final json = toJson();
    json.remove('xmppPassword');
    json.remove('token');
    json.remove('refreshToken');
    json.remove('fileToken');
    return json;
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
      'photoUrl': photoUrl,
      'fileToken': fileToken,
      'appLanguage': appLanguage,
      'chatLanguage': chatLanguage,
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
      photoUrl: json['photoUrl']?.toString(),
      fileToken: json['fileToken']?.toString(),
      appLanguage: _nonEmpty(json['appLanguage']),
      chatLanguage: _nonEmpty(json['chatLanguage']),
    );
  }
}
