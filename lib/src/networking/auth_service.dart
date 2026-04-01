import '../models/chat_component_config.dart';
import '../models/chat_user.dart';
import 'api_client.dart';
import '../core/chat_component_log.dart';

class AuthService {
  AuthService({
    required this.apiClient,
    required this.config,
    required this.log,
  });

  final ApiClient apiClient;
  final ChatComponentConfig config;
  final void Function(ChatLogEvent event) log;

  Future<ChatUser> loginWithEmail({
    required String email,
    required String password,
  }) async {
    final body = await apiClient.post(
      '/users/login-with-email',
      body: <String, dynamic>{'email': email, 'password': password},
      headers: <String, String>{'Authorization': config.customAppToken ?? ''},
    );
    log(
      ChatLogEvent(
        level: ChatLogLevel.info,
        category: ChatLogCategory.auth,
        message: 'Email login successful',
        timestamp: DateTime.now(),
      ),
    );
    return ChatUser.fromLoginResponse(body);
  }

  Future<ChatUser> loginWithJwt(String jwtToken) async {
    final body = await apiClient.post(
      '/users/client',
      headers: <String, String>{'x-custom-token': jwtToken},
    );
    log(
      ChatLogEvent(
        level: ChatLogLevel.info,
        category: ChatLogCategory.auth,
        message: 'JWT login successful',
        timestamp: DateTime.now(),
      ),
    );
    return ChatUser.fromLoginResponse(body);
  }
}
