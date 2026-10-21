import '../push/push_token_type.dart';
import 'chat_room.dart';
import 'chat_user.dart';
import 'chat_message.dart';
import 'video_calls_config.dart';

typedef OnMessageSent = Future<void> Function(ChatMessageSentEvent event);

class ChatMessageSentEvent {
  const ChatMessageSentEvent({
    required this.message,
    required this.roomJid,
    required this.messageId,
    required this.sentAt,
  });

  final ChatMessage message;
  final String roomJid;
  final String messageId;
  final DateTime sentAt;
}

class ChatEventHandlers {
  const ChatEventHandlers({this.onMessageSent});

  final OnMessageSent? onMessageSent;
}

class NotificationOffset {
  const NotificationOffset({
    this.left = 20,
    this.right = 20,
    this.top = 20,
    this.bottom = 20,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;
}

class NotificationPosition {
  const NotificationPosition({
    this.horizontal = 'left',
    this.vertical = 'bottom',
    this.offset = const NotificationOffset(),
  });

  final String horizontal;
  final String vertical;
  final NotificationOffset offset;
}

class InAppNotificationsConfig {
  const InAppNotificationsConfig({
    this.enabled = false,
    this.showInContext = true,
    this.position = const NotificationPosition(),
  });

  final bool enabled;
  final bool showInContext;
  final NotificationPosition position;
}

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
    this.roomJID,
    this.eventHandlers,
    this.inAppNotifications,
    this.qrUrl,
    this.botMessageAutoScroll = true,
    this.disableTypingIndicator = false,
    this.chatHeaderSettings,
    this.whitelistSystemMessage = const <String>[],
    this.attachments,
    this.disableReactions,
    this.reactions,
    this.disableReplies,
    this.disableLastRead,
    this.colorScheme,
    this.typography,
    this.i18n,
    this.translates,
    this.settings,
    this.logout,
    this.receipts,
    this.pushNotifications,
    this.enableMessageSearch,
    this.disableMessageSearch,
    this.disableRoomSwipeActions,
    this.disablePublicChatsDirectory,
    this.trustedEventSenders,
    this.videoCalls,
    this.e2ee,
    this.filesTab,
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
  final String? roomJID;
  final ChatEventHandlers? eventHandlers;
  final InAppNotificationsConfig? inAppNotifications;
  final String? qrUrl;
  final bool botMessageAutoScroll;
  final bool disableTypingIndicator;
  final ChatHeaderSettingsConfig? chatHeaderSettings;
  final List<String> whitelistSystemMessage;

  /// Composer limits for one media message (web config.attachments).
  final ChatAttachmentsConfig? attachments;

  /// Hard off switch for emoji reactions (chips, quick bar and picker).
  final bool? disableReactions;

  /// Reaction options: enabled flag, quick bar shortcodes, full picker.
  final ReactionsConfig? reactions;

  /// Hides only the "Reply" menu item. Threads still open from the reply
  /// count pill or the quote.
  final bool? disableReplies;

  /// Turns off the room read marker (XEP-0333 displayed marker) sent to
  /// the room, like web `disableLastRead`.
  final bool? disableLastRead;

  /// Light, dark or follow the OS (`system`). Defaults to light.
  final ChatColorScheme? colorScheme;

  /// Font family, base size and weights for the SDK UI.
  final ChatTypography? typography;

  /// UI captions locale and host string overrides.
  final ChatI18nConfig? i18n;

  /// Incoming message translation display.
  final ChatTranslatesConfig? translates;

  /// Account settings screen: languages and change password.
  final ChatSettingsConfig? settings;

  /// Logout button and confirmation.
  final ChatLogoutConfig? logout;

  /// Delivery and read receipt policy (web `receipts`).
  final ReceiptsConfig? receipts;

  /// Push registration (web/RN `pushNotifications`). The host passes its
  /// device token to `controller.registerPushToken`; the SDK has no
  /// Firebase dependency.
  final PushNotificationsConfig? pushNotifications;

  /// Opt-in message search (web `enableMessageSearch`). Needs [appId].
  final bool? enableMessageSearch;

  /// Hard off for message search, wins over [enableMessageSearch].
  final bool? disableMessageSearch;

  /// Removes the mute, report and leave swipe actions of the room list.
  final bool? disableRoomSwipeActions;

  /// Removes the public chats directory ("Discover chats").
  final bool? disablePublicChatsDirectory;

  /// When set, `ethora-event` headlines are only trusted from these senders
  /// (full JID or localpart). Null or empty trusts the server's own domain.
  final List<String>? trustedEventSenders;

  /// 1:1 and group audio/video calls (web `videoCalls`). Off by default.
  final VideoCallsConfig? videoCalls;

  /// End-to-end encryption switch (web `e2ee.enabled`). Off by default.
  /// Here it only controls whether an encrypted 1:1 chat is offered when
  /// creating a chat; the OMEMO crypto itself is not part of this SDK yet.
  final E2eeConfig? e2ee;

  /// The Files tab of the room list (web `filesTab`). Null shows it and hides
  /// it again if the backend has no `/v2/files`.
  final FilesTabConfig? filesTab;

  String get normalizedBaseUrl {
    final raw = (baseUrl ?? 'https://api.chat.ethora.com').trim();
    if (raw.endsWith('/v1')) {
      return raw;
    }
    if (raw.endsWith('/v1/')) {
      return raw.substring(0, raw.length - 1);
    }
    return raw.endsWith('/') ? '${raw}v1' : '$raw/v1';
  }
}

/// Web config.attachments: how many files one message may carry (default 10,
/// the hard cap of the stanza payload) and the per-file size ceiling in MB
/// (null skips the client-side check).
class ChatAttachmentsConfig {
  const ChatAttachmentsConfig({this.maxFiles, this.maxFileSizeMb});

  final int? maxFiles;
  final double? maxFileSizeMb;
}

class ReactionsConfig {
  const ReactionsConfig({
    this.enabled = true,
    this.quickReactions = const <String>[],
    this.picker = true,
  });

  /// Turns reactions off when false (same as disableReactions).
  final bool enabled;

  /// Shortcodes shown in the quick bar. Only the first 8 are used; empty
  /// means the default bar (joy, heart, fire, +1, smile, scream).
  final List<String> quickReactions;

  /// Shows the full emoji picker next to the quick bar.
  final bool picker;
}

class ChatColors {
  const ChatColors({
    required this.primary,
    required this.secondary,
    this.icons,
    this.iconsBg,
    this.ownMessageBackground,
    this.otherMessageBackground,
    this.inputBackground,
  });
  final String primary;
  final String secondary;

  /// Icon colour. Falls back to [primary].
  final String? icons;

  /// Icon chip background. Falls back to [secondary].
  final String? iconsBg;

  /// Own message bubble background. Default #E7EDF9 in light.
  final String? ownMessageBackground;

  /// Other users' bubble background. Default #FFFFFF in light.
  final String? otherMessageBackground;

  /// Composer background. Default #FFFFFF in light.
  final String? inputBackground;
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
    this.xmppServerUrl,
    this.devServer,
    required this.host,
    required this.conference,
    this.xmppPingOnSendEnabled = true,
  });

  final String? xmppServerUrl;
  final String? devServer;
  final String host;
  final String conference;
  final bool xmppPingOnSendEnabled;

  String get endpoint {
    final preferred = (devServer ?? '').trim();
    if (preferred.isNotEmpty) {
      return preferred;
    }
    final fallback = (xmppServerUrl ?? '').trim();
    if (fallback.isNotEmpty) {
      return fallback;
    }
    return 'wss://$host/ws';
  }
}

typedef RefreshFunction = Future<RefreshResult?> Function();

class RefreshTokensConfig {
  const RefreshTokensConfig({required this.enabled, this.refreshFunction});

  final bool enabled;
  final RefreshFunction? refreshFunction;
}

/// What a host `refreshFunction` returns. Return [refreshToken] when your
/// flow rotates one; otherwise the stored one is kept (and, on a rotating
/// backend, will look like token reuse). [fileToken] and [xmppPassword] are
/// stored when present.
class RefreshResult {
  const RefreshResult({
    required this.accessToken,
    this.refreshToken,
    this.fileToken,
    this.xmppPassword,
  });

  final String accessToken;
  final String? refreshToken;
  final String? fileToken;
  final String? xmppPassword;
}

class ChatHeaderSettingsConfig {
  const ChatHeaderSettingsConfig({
    this.roomTitleOverrides = const <String, String>{},
    this.chatInfoButtonDisabled = false,
    this.backButtonDisabled = false,
    this.hideSearch = false,
  });

  final Map<String, String> roomTitleOverrides;
  final bool chatInfoButtonDisabled;
  final bool backButtonDisabled;

  /// Hides the header search button only (search stays reachable elsewhere).
  final bool hideSearch;
}

/// Light or dark palette. `system` follows the platform brightness.
enum ChatColorScheme { light, dark, system }

/// Font configuration. [fontFamily] must name a family the host bundles in
/// its pubspec (Flutter does not download fonts from URLs).
class ChatTypography {
  const ChatTypography({
    this.fontFamily,
    this.fontSize,
    this.weights,
  });

  /// Family name, optionally followed by fallbacks: "Inter, sans-serif".
  final String? fontFamily;

  /// Base size: a number is pixels (`18`), a string may carry a unit
  /// (`"1.1rem"`, `"18px"`). Default 16 px.
  final Object? fontSize;

  /// Weight tokens, kept for parity with the web config. Not applied yet.
  final Map<String, int>? weights;
}

/// UI locale and string overrides. [locale] is BCP-47, resolved to its base
/// language. [strings] override built-in captions by key.
class ChatI18nConfig {
  const ChatI18nConfig({this.locale, this.strings});

  final String? locale;
  final Map<String, String>? strings;
}

/// Context passed to [ChatTranslatesConfig.onTranslate].
class ChatTranslateContext {
  const ChatTranslateContext({
    this.sourceLocale,
    required this.targetLocale,
    required this.messageId,
  });

  final String? sourceLocale;
  final String targetLocale;
  final String messageId;
}

typedef OnTranslate = Future<String> Function(
  String text,
  ChatTranslateContext context,
);

/// Incoming message translation display.
class ChatTranslatesConfig {
  const ChatTranslatesConfig({
    this.enabled = false,
    this.mode = 'auto',
    this.readerLocale,
    this.onTranslate,
    this.showTranslateForMessage,
  });

  final bool enabled;

  /// `auto` shows the translation inline. `manual` shows a "Translate" link.
  final String mode;

  /// Reader's full locale. Falls back to `i18n.locale`, then to the
  /// reader's chat language.
  final String? readerLocale;

  /// Host translation function, used by the manual action.
  final OnTranslate? onTranslate;

  /// Host predicate that decides whether a message shows the action.
  final bool Function(ChatMessage message)? showTranslateForMessage;
}

/// One selectable language: BCP-47 [id] and the language's own [name].
class ChatLanguageOption {
  const ChatLanguageOption({required this.id, required this.name});

  final String id;
  final String name;
}

/// Language pickers on the account settings screen (web `settings.languages`).
class ChatLanguagesConfig {
  const ChatLanguagesConfig({
    this.enabled = false,
    this.appLanguages,
    this.chatLanguages,
  });

  /// Shows the interface and chat language pickers. The choices are written
  /// to the profile as `appLanguage` and `chatLanguage`.
  final bool enabled;

  /// Options for the interface language. Defaults to en-CA, es-US, fr-CA.
  final List<ChatLanguageOption>? appLanguages;

  /// Options for the chat language. Defaults to en-CA, es-US, fr-CA.
  final List<ChatLanguageOption>? chatLanguages;
}

/// Account settings (web `settings`).
class ChatSettingsConfig {
  const ChatSettingsConfig({
    this.languages,
    this.changePassword = false,
    this.onExportData,
    this.hidePushToggle = false,
  });

  final ChatLanguagesConfig? languages;

  /// Shows the change password action.
  final bool changePassword;

  /// Receives the account data export (UTF-8 JSON [bytes]) so the host can
  /// save or share it. Without it the settings screen shows the data in a
  /// copyable dialog, because the SDK has no file-system dependency.
  final Future<void> Function(List<int> bytes, String fileName)? onExportData;

  /// Hides the push on/off switch in Settings (web `settings.hidePushToggle`).
  final bool hidePushToggle;
}

/// Logout button and confirmation.
class ChatLogoutConfig {
  const ChatLogoutConfig({
    this.enabled = true,
    this.confirm = true,
    this.onBeforeLogout,
    this.onAfterLogout,
  });

  final bool enabled;
  final bool confirm;
  final Future<void> Function()? onBeforeLogout;
  final Future<void> Function()? onAfterLogout;
}

/// Delivery (XEP-0184) and read (XEP-0333) receipt policy, same keys and
/// defaults as web `receipts`. `auto` limits receipts by room size and
/// message age, `all` always sends them, `off` never does.
class ReceiptsConfig {
  const ReceiptsConfig({
    this.mode = 'auto',
    this.deliveryMaxRoomSize = 20,
    this.readMaxRoomSize = 100,
    this.maxAgeDays = 7,
    this.coalesceMs = 1500,
  });

  final String mode;
  final int deliveryMaxRoomSize;
  final int readMaxRoomSize;
  final int maxAgeDays;
  final int coalesceMs;
}

/// Push notifications (web/RN `pushNotifications`). The host obtains the
/// device token (FCM, APNs) and passes it to the controller.
class PushNotificationsConfig {
  const PushNotificationsConfig({
    this.enabled = true,
    this.apiUrl,
    this.projectName,
    this.getPushTokens,
  });

  /// False turns registration and MucSub subscription off.
  final bool enabled;

  /// Push gateway base URL, e.g. `https://push.chat.ethora.com/api/v1`.
  /// When set, tokens go to `{apiUrl}/subscriptions` instead of the Ethora
  /// backend.
  final String? apiUrl;

  /// Gateway project name. Required when [apiUrl] is set.
  final String? projectName;

  /// Supplies the device token(s) once the user is signed in, so the host
  /// does not have to time `registerPushToken` itself. Called at login and
  /// bootstrap (once per account; a failure is retried after 30 s) and again
  /// on `controller.refreshPushTokens()`. Return the chat token and, on iOS,
  /// the VoIP one. The hook runs in addition to `registerPushToken`.
  final Future<List<PushTokenRegistration>> Function()? getPushTokens;
}

/// A device token the host hands to the SDK. A null [tokenType] is detected
/// from the token (64+ hex characters is APNs, else FCM).
class PushTokenRegistration {
  const PushTokenRegistration({required this.token, this.tokenType});

  final String token;
  final PushTokenType? tokenType;
}

/// Web `config.e2ee`.
class E2eeConfig {
  const E2eeConfig({this.enabled = false});

  final bool enabled;
}

/// Web `config.filesTab`: `enabled: true` always shows the Files tab,
/// `false` always hides it, null shows it until the first list request
/// answers 404 or 501.
class FilesTabConfig {
  const FilesTabConfig({this.enabled});

  final bool? enabled;
}
