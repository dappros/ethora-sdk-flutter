import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_user.dart';

/// Persists the session. Non-secret profile data goes to SharedPreferences;
/// tokens and the XMPP password go to the platform keystore/keychain via
/// flutter_secure_storage, never to plain preferences.
class ChatComponentStore {
  ChatComponentStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  static const _keyUser = 'ethora_chat_component.user';
  static const _keyToken = 'ethora_chat_component.token';
  static const _keyRefreshToken = 'ethora_chat_component.refresh_token';
  static const _keyXmppPassword = 'ethora_chat_component.xmpp_password';
  static const _keyFileToken = 'ethora_chat_component.file_token';

  Future<ChatUser?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyUser);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final user = ChatUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    return user.copyWith(
      xmppPassword: await _secure.read(key: _keyXmppPassword),
      token: await _secure.read(key: _keyToken),
      refreshToken: await _secure.read(key: _keyRefreshToken),
      fileToken: await _secure.read(key: _keyFileToken),
    );
  }

  Future<void> setUser(ChatUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUser, jsonEncode(user.toPublicJson()));
    await _writeSecret(_keyXmppPassword, user.xmppPassword);
    await _writeSecret(_keyToken, user.token);
    await _writeSecret(_keyRefreshToken, user.refreshToken);
    await _writeSecret(_keyFileToken, user.fileToken);
  }

  Future<void> _writeSecret(String key, String? value) async {
    if (value == null || value.isEmpty) return;
    await _secure.write(key: key, value: value);
  }

  Future<void> clearUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUser);
    await _secure.delete(key: _keyXmppPassword);
    await _secure.delete(key: _keyFileToken);
  }

  Future<String?> getToken() => _secure.read(key: _keyToken);

  Future<void> setToken(String token) =>
      _secure.write(key: _keyToken, value: token);

  Future<String?> getRefreshToken() => _secure.read(key: _keyRefreshToken);

  Future<void> setRefreshToken(String refreshToken) =>
      _secure.write(key: _keyRefreshToken, value: refreshToken);

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUser);
    // Older versions kept tokens in plain preferences; wipe those too.
    await prefs.remove(_keyToken);
    await prefs.remove(_keyRefreshToken);
    for (final key in <String>[
      _keyToken,
      _keyRefreshToken,
      _keyXmppPassword,
      _keyFileToken,
    ]) {
      await _secure.delete(key: key);
    }
  }
}
