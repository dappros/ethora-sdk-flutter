import 'chat_room.dart';
import 'chat_user.dart';

class ChatComponentConfig {
  const ChatComponentConfig({
    this.appId,
    this.baseUrl,
    this.customAppToken,
    this.disableHeader,
    this.disableMedia,
    this.colors,
    this.googleLogin,
    this.jwtLogin,
    this.userLogin,
    this.customLogin,
    this.xmppSettings,
    this.disableRooms,
    this.defaultLogin,
    this.disableInteractions,
    this.chatHeaderBurgerMenu,
    this.forceSetRoom,
    this.setRoomJidInPath,
    this.disableRoomMenu,
    this.disableRoomConfig,
    this.disableNewChatButton,
    this.defaultRooms,
    this.refreshTokens,
    this.disableProfilesInteractions,
    this.disableUserCount,
    this.clearStoreBeforeInit,
    this.disableSentLogic,
    this.initBeforeLoad,
    this.newArch = true,
    this.qrUrl,
    this.botMessageAutoScroll = true,
    this.disableTypingIndicator = false,
    this.chatHeaderSettings,
    this.whitelistSystemMessage = const <String>[],
  });

  final String? appId;
  final String? baseUrl;
  final String? customAppToken;
  final bool? disableHeader;
  final bool? disableMedia;
  final ChatColors? colors;
  final GoogleLoginConfig? googleLogin;
  final JwtLoginConfig? jwtLogin;
  final UserLoginConfig? userLogin;
  final CustomLoginConfig? customLogin;
  final XmppSettings? xmppSettings;
  final bool? disableRooms;
  final bool? defaultLogin;
  final bool? disableInteractions;
  final bool? chatHeaderBurgerMenu;
  final bool? forceSetRoom;
  final bool? setRoomJidInPath;
  final bool? disableRoomMenu;
  final bool? disableRoomConfig;
  final bool? disableNewChatButton;
  final List<ChatRoom>? defaultRooms;
  final RefreshTokensConfig? refreshTokens;
  final bool? disableProfilesInteractions;
  final bool? disableUserCount;
  final bool? clearStoreBeforeInit;
  final bool? disableSentLogic;
  final bool? initBeforeLoad;
  final bool? newArch;
  final String? qrUrl;
  final bool botMessageAutoScroll;
  final bool disableTypingIndicator;
  final ChatHeaderSettingsConfig? chatHeaderSettings;
  final List<String> whitelistSystemMessage;

  String get normalizedBaseUrl {
    final raw = (baseUrl ?? 'https://api.ethoradev.com').trim();
    if (raw.endsWith('/v1')) {
      return raw;
    }
    if (raw.endsWith('/v1/')) {
      return raw.substring(0, raw.length - 1);
    }
    return raw.endsWith('/') ? '${raw}v1' : '$raw/v1';
  }
}

class ChatColors {
  const ChatColors({required this.primary, required this.secondary});
  final String primary;
  final String secondary;
}

class FirebaseConfig {
  const FirebaseConfig({
    required this.apiKey,
    required this.authDomain,
    required this.projectId,
    required this.storageBucket,
    required this.messagingSenderId,
    required this.appId,
  });

  final String apiKey;
  final String authDomain;
  final String projectId;
  final String storageBucket;
  final String messagingSenderId;
  final String appId;
}

class GoogleLoginConfig {
  const GoogleLoginConfig({
    required this.enabled,
    required this.firebaseConfig,
  });

  final bool enabled;
  final FirebaseConfig firebaseConfig;
}

class JwtLoginConfig {
  const JwtLoginConfig({required this.enabled, required this.token});

  final bool enabled;
  final String token;
}

class UserLoginConfig {
  const UserLoginConfig({required this.enabled, required this.user});
  final bool enabled;
  final ChatUser? user;
}

typedef LoginFunction = Future<ChatUser?> Function();

class CustomLoginConfig {
  const CustomLoginConfig({required this.enabled, required this.loginFunction});
  final bool enabled;
  final LoginFunction loginFunction;
}

class XmppSettings {
  const XmppSettings({
    required this.xmppServerUrl,
    required this.host,
    required this.conference,
    this.xmppPingOnSendEnabled = true,
  });

  final String xmppServerUrl;
  final String host;
  final String conference;
  final bool xmppPingOnSendEnabled;
}

typedef RefreshFunction = Future<RefreshResult?> Function();

class RefreshTokensConfig {
  const RefreshTokensConfig({required this.enabled, this.refreshFunction});

  final bool enabled;
  final RefreshFunction? refreshFunction;
}

class RefreshResult {
  const RefreshResult({required this.accessToken, this.refreshToken});

  final String accessToken;
  final String? refreshToken;
}

class ChatHeaderSettingsConfig {
  const ChatHeaderSettingsConfig({
    this.roomTitleOverrides = const <String, String>{},
    this.chatInfoButtonDisabled = false,
    this.backButtonDisabled = false,
  });

  final Map<String, String> roomTitleOverrides;
  final bool chatInfoButtonDisabled;
  final bool backButtonDisabled;
}
