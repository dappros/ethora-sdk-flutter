import '../networking/xmpp_client.dart';

class PrivateStoreSyncService {
  Future<Map<String, int>> read(XmppClient? xmpp) async {
    if (xmpp == null) return const <String, int>{};
    final raw = await xmpp.getChatsPrivateStore();
    final out = <String, int>{};
    raw.forEach((key, value) {
      final ts = int.tryParse(value.toString()) ?? 0;
      if (ts > 0) {
        out[key] = ts;
      }
    });
    return out;
  }

  Future<void> write(
    XmppClient? xmpp, {
    required String roomJid,
    required int timestamp,
  }) async {
    if (xmpp == null || roomJid.isEmpty || timestamp <= 0) return;
    await xmpp.setTimestampToPrivateStore(
      chatId: roomJid,
      timestamp: timestamp,
    );
  }
}
