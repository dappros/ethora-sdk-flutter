import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes base URL by appending /v1 when missing', () {
    const config = ChatComponentConfig(baseUrl: 'https://api.chat.ethora.com');
    expect(config.normalizedBaseUrl, 'https://api.chat.ethora.com/v1');
  });

  test('keeps /v1 when already present', () {
    const config = ChatComponentConfig(baseUrl: 'https://api.chat.ethora.com/v1');
    expect(config.normalizedBaseUrl, 'https://api.chat.ethora.com/v1');
  });

  test('xmpp endpoint prefers devServer over xmppServerUrl', () {
    const settings = XmppSettings(
      devServer: 'wss://xmpp.ethora/ws',
      xmppServerUrl: 'wss://fallback/ws',
      host: 'xmpp.ethora',
      conference: 'conference.xmpp.ethora',
    );
    expect(settings.endpoint, 'wss://xmpp.ethora/ws');
  });

  test('supports roomJID and inAppNotifications config', () {
    const config = ChatComponentConfig(
      roomJID: 'room@conference.xmpp.test',
      inAppNotifications: InAppNotificationsConfig(
        enabled: true,
        showInContext: true,
      ),
    );
    expect(config.roomJID, 'room@conference.xmpp.test');
    expect(config.inAppNotifications?.enabled, true);
  });
}
