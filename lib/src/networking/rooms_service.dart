import '../models/chat_component_config.dart';
import '../models/chat_room.dart';
import 'api_client.dart';
import '../core/chat_component_log.dart';

class RoomsService {
  RoomsService({
    required this.apiClient,
    required this.config,
    required this.log,
  });

  final ApiClient apiClient;
  final ChatComponentConfig config;
  final void Function(ChatLogEvent event) log;

  Future<List<ChatRoom>> getRooms() async {
    final body = await apiClient.get(
      '/chats/my',
      headers: <String, String>{'x-app-id': config.appId ?? ''},
    );
    final items = (body['items'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(ChatRoom.fromApi)
        .toList();
    log(
      ChatLogEvent(
        level: ChatLogLevel.info,
        category: ChatLogCategory.rooms,
        message: 'Loaded ${items.length} rooms',
        timestamp: DateTime.now(),
      ),
    );
    return items;
  }
}
