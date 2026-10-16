import '../models/chat_component_config.dart';
import '../models/chat_room.dart';

class ResolvedConfig {
  const ResolvedConfig({
    required this.normalizedBaseUrl,
    required this.xmppEndpoint,
    required this.forcedRoomJid,
    required this.defaultRooms,
  });

  final String normalizedBaseUrl;
  final String xmppEndpoint;
  final String? forcedRoomJid;
  final List<ChatRoom> defaultRooms;
}

class ConfigResolver {
  const ConfigResolver();

  ResolvedConfig resolve(ChatComponentConfig config) {
    final forcedRoomJid = (config.roomJID ?? '').trim().isEmpty
        ? null
        : config.roomJID!.trim();
    return ResolvedConfig(
      normalizedBaseUrl: config.normalizedBaseUrl,
      xmppEndpoint: config.xmppSettings?.endpoint ?? '',
      forcedRoomJid: forcedRoomJid,
      defaultRooms: config.defaultRooms ?? const <ChatRoom>[],
    );
  }
}
