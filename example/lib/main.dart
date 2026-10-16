import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/ui/app.dart';
import 'package:flutter/widgets.dart';

const kEthoraChatAppId = '646cc8dc96d4a4dc8f7b2f2d';
const kEthoraApiUrl = 'https://api.ethoradev.com/v1';
const kEthoraApiToken = 'JWT token';

void main() {
  final config = ChatComponentConfig(
    roomJID: '',
    appId: kEthoraChatAppId,
    baseUrl: kEthoraApiUrl,
    customAppToken: kEthoraApiToken,
    defaultLogin: true,
    initBeforeLoad: true,
    disableMedia: true,
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
      devServer: 'wss://xmpp.ethoradev.com:5443/ws',
      host: 'xmpp.ethoradev.com',
      conference: 'conference.xmpp.ethoradev.com',
      xmppPingOnSendEnabled: true,
    ),
  );

  final controller = ChatComponentController(config: config);
  final app = ChatComponentDemoApp(controller: controller, config: config);
  runApp(app);
}
