import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Key under which the MucSub-subscribed rooms are remembered (same key as
/// the RN SDK).
const String kSubscribedRoomsKey = 'ethora_subscribed_rooms';

/// Key of the pending room opened by a tapped push (RN
/// `ethora_pending_notification_jid`).
const String kPendingNotificationJidKey = 'ethora_pending_notification_jid';

/// The user's own push switch (RN `chatSettingStore.pushEnabled`).
const String kPushEnabledKey = 'ethora_chat_component.push_enabled';

/// A tapped push waits this long for its room to load.
const Duration kPendingNotificationTtl = Duration(minutes: 5);

/// Small durable key-value surface the push feature needs. The default
/// implementation uses SharedPreferences; tests use an in-memory map.
abstract class PushStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class SharedPreferencesPushStorage implements PushStorage {
  const SharedPreferencesPushStorage();

  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

class MemoryPushStorage implements PushStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// `{"jid": "...", "at": ms}` for the pending notification room.
String encodePendingJid(String jid, DateTime at) =>
    jsonEncode(<String, dynamic>{'jid': jid, 'at': at.millisecondsSinceEpoch});

/// The pending room jid, or null when absent or older than [kPendingNotificationTtl].
String? decodePendingJid(String? raw, DateTime now) {
  if (raw == null || raw.isEmpty) return null;
  try {
    if (raw.startsWith('{')) {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final jid = decoded['jid'];
      final at = decoded['at'];
      if (jid is! String || jid.isEmpty || at is! num) return null;
      final age = now.millisecondsSinceEpoch - at.toInt();
      return age > kPendingNotificationTtl.inMilliseconds ? null : jid;
    }
    return raw;
  } catch (_) {
    return null;
  }
}
