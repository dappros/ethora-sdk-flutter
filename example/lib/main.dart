import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'demo_app.dart';
import 'package:flutter/widgets.dart';

const kEthoraChatAppId = '646cc8dc96d4a4dc8f7b2f2d';
const kEthoraApiUrl = 'https://api.chat.ethora.com/v1';
const kEthoraApiToken = 'JWT token';

void main() {
  final config = ChatComponentConfig(
    roomJID: '',
    appId: kEthoraChatAppId,
    baseUrl: kEthoraApiUrl,
    customAppToken: kEthoraApiToken,
    defaultLogin: true,
    initBeforeLoad: true,
    colorScheme: ChatColorScheme.system,
    enableMessageSearch: true,
    videoCalls: const VideoCallsConfig(
      enabled: true,
      livekitUrl: 'wss://livekit.example.com',
      enableAudioCalls: true,
    ),
    settings: const ChatSettingsConfig(changePassword: true),
    refreshTokens: const RefreshTokensConfig(enabled: true),
    jwtLogin: const JwtLoginConfig(enabled: true, token: 'token'),
    userLogin: const UserLoginConfig(enabled: true, user: null),
    eventHandlers: ChatEventHandlers(
      onMessageSent: (event) async {},
    ),
    inAppNotifications: const InAppNotificationsConfig(
      enabled: true,
      showInContext: true,
      position: NotificationPosition(
        horizontal: 'left',
        vertical: 'bottom',
        offset: NotificationOffset(left: 20, bottom: 20),
      ),
    ),
    xmppSettings: const XmppSettings(
      xmppServerUrl: 'wss://xmpp.chat.ethora.com/ws',
      host: 'xmpp.chat.ethora.com',
      conference: 'conference.xmpp.chat.ethora.com',
      xmppPingOnSendEnabled: true,
    ),
  );

  final controller = ChatComponentController(config: config);
  final app = ChatComponentDemoApp(controller: controller, config: config);
  runApp(app);
}
