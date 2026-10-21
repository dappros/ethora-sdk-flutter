import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/chat_component_config.dart';
import '../models/chat_message.dart';
import '../models/chat_room.dart';
import '../models/chat_user.dart';
import 'chat_component_log.dart';
import 'chat_component_state.dart';
import 'chat_component_store.dart';
import 'config_resolver.dart';
import 'history_queue_service.dart';
import 'private_store_sync_service.dart';
import 'send_queue_service.dart';
import 'unread_service.dart';
import '../models/media_attachment.dart';
import '../networking/api_client.dart';
import '../networking/auth_refresh.dart';
import '../networking/auth_service.dart';
import '../networking/media_upload_service.dart';
import '../networking/rooms_service.dart';
import '../networking/stanza_parser.dart';
import '../networking/user_api.dart';
import '../networking/xmpp_client.dart';
import '../networking/xmpp_credentials.dart';
import '../calls/call_log.dart';
import '../calls/calls_coordinator.dart';
import '../calls/calls_platform.dart';
import '../models/video_calls_config.dart';
import '../push/chat_push_coordinator.dart';
import '../push/push_api.dart';
import '../push/push_payload.dart';
import '../push/push_registration.dart';
import '../i18n/chat_i18n.dart';
import 'message_reference.dart';
import 'receipts.dart';
import 'history_cursor.dart';
import 'jump_window.dart';
import 'message_search_session.dart';
import 'room_events.dart';
import '../networking/message_search_service.dart';
import '../networking/room_actions_service.dart';
import '../networking/files_service.dart';
import 'my_files_model.dart';

part 'controller_messaging.dart';
part 'controller_jump.dart';
part 'controller_rooms.dart';
part 'controller_auth.dart';
part 'controller_account.dart';
part 'controller_push.dart';
part 'controller_calls.dart';

typedef XmppClientFactory = XmppClient Function({
  required XmppSettings settings,
  required ChatUser user,
  required void Function(ChatLogEvent event) log,
});

enum _HeapKind { text, media }

class _PendingHeapItem {
  const _PendingHeapItem.text({
    required this.messageId,
    required this.roomJid,
    required this.text,
    this.isReply = false,
    this.showInChannel = false,
    this.mainMessage = '',
  })  : kind = _HeapKind.text,
        mediaUrl = null,
        mimeType = null,
        file = null,
        files = const <Map<String, dynamic>>[],
        caption = null;

  const _PendingHeapItem.media({
    required this.messageId,
    required this.roomJid,
    required this.mediaUrl,
    required this.mimeType,
    required this.file,
    this.files = const <Map<String, dynamic>>[],
    this.caption,
  })  : kind = _HeapKind.media,
        text = null,
        isReply = false,
        showInChannel = false,
        mainMessage = '';

  final _HeapKind kind;
  final String messageId;
  final String roomJid;
  final String? text;

  /// Thread reply fields of a text message (empty for a channel message).
  final bool isReply;
  final bool showInChannel;
  final String mainMessage;
  final String? mediaUrl;
  final String? mimeType;
  final Map<String, dynamic>? file;

  /// Every upload result of a multi-file message, in order (empty = [file]).
  final List<Map<String, dynamic>> files;
  final String? caption;
}

/// Pending text turns into "failed" after this long without a server echo
/// (web PENDING_WATCHDOG_MS / MEDIA_PENDING_WATCHDOG_MS).
const Duration kTextPendingWatchdog = Duration(seconds: 10);
const Duration kMediaPendingWatchdog = Duration(seconds: 30);

/// A typer is dropped if no "paused" arrives within this window.
const Duration kTypingExpiry = Duration(seconds: 8);

class ChatComponentController {
  ChatComponentController({
    required this.config,
    ChatComponentStore? store,
    ApiClient? apiClient,
    AuthService? authService,
    RoomsService? roomsService,
    XmppClientFactory? xmppClientFactory,
  }) : _store = store ?? ChatComponentStore() {
    _apiClient = apiClient ??
        ApiClient(
          config: config,
          readAccessToken: _store.getToken,
          readRefreshToken: _store.getRefreshToken,
          writeTokens: _writeRotatedTokens,
          writeFileToken: _onFileTokenRefreshed,
          writeXmppPassword: _onXmppPasswordRefreshed,
          hostRecovery: _attemptHostRecovery,
          clearSession: _onSessionExpired,
          log: _emitLog,
        );
    _mediaUploads = MediaUploadService(apiClient: _apiClient, log: _emitLog);
    _authService = authService ??
        AuthService(apiClient: _apiClient, config: config, log: _emitLog);
    _roomsService = roomsService ??
        RoomsService(apiClient: _apiClient, config: config, log: _emitLog);
    _xmppClientFactory = xmppClientFactory ?? XmppClient.new;
    _sendQueue.bindConnectivity(
      () => _xmpp?.state == ChatConnectionState.online,
    );
  }

  final ChatComponentConfig config;
  final ChatComponentStore _store;
  final ConfigResolver _configResolver = const ConfigResolver();
  final UnreadService _unreadService = const UnreadService();
  final SendQueueService _sendQueue = SendQueueService();
  final HistoryQueueService _historyQueue = HistoryQueueService();
  final PrivateStoreSyncService _privateStoreSync = PrivateStoreSyncService();
  final List<_PendingHeapItem> _pendingHeap = <_PendingHeapItem>[];
  final Set<String> _sentCallbackDeliveredFor = <String>{};
  final Map<String, int> _roomEpoch = <String, int>{};
  final Map<String, Timer> _pendingWatchdogs = <String, Timer>{};
  final Map<String, Map<String, (String, Timer)>> _typers =
      <String, Map<String, (String, Timer)>>{};
  final Set<String> _historyInFlight = <String>{};

  /// Reactions whose target message is not loaded yet, applied on arrival:
  /// room -> target archive id -> reactor -> reaction.
  final Map<String, Map<String, Map<String, ChatReaction>>> _parkedReactions =
      <String, Map<String, Map<String, ChatReaction>>>{};
  DeliveryReceiptBatcher? _deliveryBatcher;
  final Map<String, DisplayedMarkerThrottle> _displayedThrottles =
      <String, DisplayedMarkerThrottle>{};
  final Map<String, Timer> _markReadTimers = <String, Timer>{};
  final Set<String> _threadHistoryInFlight = <String>{};
  final _JumpRuntime _jump = _JumpRuntime();
  final _RoomsRuntime _rooms = _RoomsRuntime();

  late final ApiClient _apiClient;
  late final MediaUploadService _mediaUploads;
  late final AuthService _authService;
  late final RoomsService _roomsService;
  XmppClient? _xmpp;
  late final XmppClientFactory _xmppClientFactory;
  Timer? _typingStopTimer;
  Future<void>? _initializing;
  bool _disposed = false;

  // Push, account and credential recovery (controller_push / _account / _auth).
  late final ChatPushCoordinator _push = ChatPushCoordinator(
    config: config,
    apiClient: _apiClient,
    state: state,
    xmpp: () => _xmpp,
    selectRoom: selectRoom,
    log: (message) => _log(ChatLogLevel.info, ChatLogCategory.system, message),
  );
  // Audio/video calls (controller_calls).
  late final CallsCoordinator _calls = createPlatformCallsCoordinator(
    host: _ControllerCallsHost(this),
    api: _apiClient,
  );
  late final UserApi _userApi = UserApi(_apiClient);
  late final XmppCredentialRecovery _xmppCredentialRecovery =
      _newXmppCredentialRecovery();
  Future<void>? _xmppAuthRecovery;
  int _xmppAuthRecoveryAttempts = 0;
  Future<bool>? _hostRecoveryInFlight;

  final ValueNotifier<ChatComponentState> state =
      ValueNotifier<ChatComponentState>(const ChatComponentState());
  final StreamController<ChatLogEvent> _logController =
      StreamController<ChatLogEvent>.broadcast();

  Stream<ChatLogEvent> get logs => _logController.stream;

  /// Safe to call more than once: concurrent calls share one run, and a
  /// finished run is not repeated until [logout].
  Future<void> initialize() {
    if (state.value.isInitialized) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    state.value = state.value.copyWith(
      isLoading: true,
      globalLoading: true,
      clearErrorMessage: true,
      requiresLogin: false,
    );

    try {
      ChatUser? user;
      if (config.userLogin?.enabled == true && config.userLogin?.user != null) {
        user = config.userLogin!.user;
      }
      user ??= await _store.getUser();

      if (user == null && config.jwtLogin?.enabled == true) {
        user = await loginJwt(config.jwtLogin!.token, initializeAfter: false);
      }

      if (user == null && config.customLogin?.enabled == true) {
        user = await config.customLogin!.loginFunction();
      }

      if (user == null) {
        state.value = state.value.copyWith(
          isLoading: false,
          globalLoading: false,
          isInitialized: false,
          requiresLogin: true,
          errorMessage: config.defaultLogin == true
              ? null
              : 'No authentication strategy succeeded.',
        );
        return;
      }

      await _applyLoggedInUser(user);
      await _initializeRuntime();
    } catch (e) {
      state.value = state.value.copyWith(
        isLoading: false,
        globalLoading: false,
        isInitialized: false,
        errorMessage: e.toString(),
      );
      _log(ChatLogLevel.error, ChatLogCategory.system,
          'Initialization failed: $e');
    }
  }

  Future<ChatUser> loginEmail(
    String email,
    String password, {
    bool initializeAfter = true,
  }) async {
    final user = await _authService.loginWithEmail(
      email: email,
      password: password,
    );
    await _applyLoggedInUser(user);
    if (initializeAfter) {
      await _initializeRuntime();
    }
    return user;
  }

  Future<ChatUser> loginJwt(
    String jwtToken, {
    bool initializeAfter = true,
  }) async {
    final user = await _authService.loginWithJwt(jwtToken);
    await _applyLoggedInUser(user);
    if (initializeAfter) {
      await _initializeRuntime();
    }
    return user;
  }

  Future<void> _applyLoggedInUser(ChatUser user) async {
    await _store.setUser(user);
    if ((user.token ?? '').isNotEmpty) {
      await _store.setToken(user.token!);
    }
    if ((user.refreshToken ?? '').isNotEmpty) {
      await _store.setRefreshToken(user.refreshToken!);
    }
    state.value = state.value.copyWith(user: user, requiresLogin: false);
    unawaited(_apiClient.auth.scheduleProactive());
  }

  String get _myLocal {
    final user = state.value.user;
    return localPart(
      user?.xmppUsername ?? user?.walletAddress ?? user?.username ?? '',
    ).toLowerCase();
  }

  /// True when [message] was written by the signed-in user. Matches web:
  /// the MUC nick (occupant resource) or `<data senderJID>` localpart.
  bool isOwnMessage(ChatMessage message) {
    final me = _myLocal;
    if (me.isEmpty) return false;
    final sender = localPart(
      message.user.xmppUsername ?? message.user.id ?? '',
    ).toLowerCase();
    if (sender == me) return true;
    final senderJid = localPart(message.data['senderJID']).toLowerCase();
    return senderJid.isNotEmpty && senderJid == me;
  }

  Future<void> _initializeRuntime() async {
    final user = state.value.user;
    if (user == null) return;

    final xmppUsername =
        user.xmppUsername ?? user.walletAddress ?? user.username;
    final xmppPassword = user.xmppPassword;
    final xmppSettings = config.xmppSettings;
    if (xmppUsername == null ||
        xmppUsername.isEmpty ||
        xmppPassword == null ||
        xmppPassword.isEmpty ||
        xmppSettings == null) {
      state.value = state.value.copyWith(
        isLoading: false,
        globalLoading: false,
        isInitialized: false,
        requiresLogin: true,
        errorMessage: 'Missing XMPP credentials or xmppSettings',
      );
      return;
    }

    await _xmpp?.disconnect();
    final xmpp = _xmppClientFactory(
      settings: xmppSettings,
      user: user.copyWith(
        xmppUsername: xmppUsername,
        xmppPassword: xmppPassword,
      ),
      log: _emitLog,
    );
    _xmpp = xmpp;
    xmpp.onConnectionChanged = (connection) {
      state.value = state.value.copyWith(connectionState: connection);
      if (connection == ChatConnectionState.online) {
        _xmppAuthRecoveryAttempts = 0;
        _sendQueue.resume();
        _historyQueue.resume();
      }
    };
    xmpp.onReconnected = () => unawaited(_onReconnected());
    xmpp.onAuthFailed = (error) {
      state.value = state.value.copyWith(errorMessage: error.toString());
      _log(ChatLogLevel.error, ChatLogCategory.xmpp, error.toString());
      _xmppAuthRecovery = _recoverXmppAuth(xmpp);
    };
    xmpp.onMessage = _handleIncomingMessage;
    xmpp.onEdit = _handleEdit;
    xmpp.onDelete = _handleDelete;
    xmpp.onReaction = _handleReaction;
    xmpp.onTyping = _handleTyping;
    _wireMessaging(xmpp);
    _wireRoomEvents(xmpp);
    _wireCalls(xmpp);

    await xmpp.connect();
    await _awaitXmppAuthRecovery();

    final resolved = _configResolver.resolve(config);
    var rooms = await _roomsService.getRooms();
    if (resolved.forcedRoomJid != null &&
        rooms.every((room) => room.jid != resolved.forcedRoomJid)) {
      rooms = <ChatRoom>[
        ...rooms,
        ChatRoom(jid: resolved.forcedRoomJid!, title: resolved.forcedRoomJid),
      ];
    }

    state.value = state.value.copyWith(rooms: rooms);
    final roomJids = _roomJids();
    if (roomJids.isNotEmpty) {
      await xmpp.sendPresenceToRooms(roomJids);
    }

    await syncPrivateStoreTimestamps();

    if (roomJids.isNotEmpty) {
      final selected = resolved.forcedRoomJid ?? roomJids.first;
      await selectRoom(selected);
    }

    state.value = state.value.copyWith(
      isLoading: false,
      globalLoading: false,
      isInitialized: true,
    );
    unawaited(_push.onRuntimeReady().catchError((Object e) {
      _log(ChatLogLevel.error, ChatLogCategory.system, 'Push setup failed: $e');
    }));
  }

  List<String> _roomJids() => state.value.rooms
      .map((e) => e.jid.trim())
      .where((jid) => jid.isNotEmpty)
      .toSet()
      .toList();

  /// After a dropped socket: re-join every room, catch up the newest page
  /// of each (selected room first) and re-send what was still pending.
  Future<void> _onReconnected() async {
    final xmpp = _xmpp;
    if (xmpp == null) return;
    final roomJids = _roomJids();
    await xmpp.sendPresenceToRooms(roomJids);
    final selected = state.value.selectedRoomJid;
    if (selected != null) {
      final page =
          await loadHistory(roomJid: selected, source: HistorySource.active);
      _ackCatchUp(selected, page);
    }
    for (final jid in roomJids.where((jid) => jid != selected)) {
      unawaited(loadHistory(roomJid: jid, source: HistorySource.background));
    }
    await recoverPendingHeap();
    unawaited(_push.onReconnected());
  }

  Future<void> selectRoom(String roomJid) async {
    final normalized = roomJid.trim();
    if (normalized.isEmpty) return;

    state.value = state.value.copyWith(selectedRoomJid: normalized);
    promoteRoomHistory(normalized);
    await _xmpp?.sendRoomPresence(normalized);
    await loadHistory(
      roomJid: normalized,
      max: 30,
      source: HistorySource.active,
    );
    await markRoomViewed(normalized);
    _recalculateUnread();
    _scheduleMarkRead(normalized);
  }

  String _newMessageId(String prefix) {
    final rnd = Random();
    final suffix = List<String>.generate(
      4,
      (_) => rnd.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'),
    ).join();
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }

  /// Sends a text message. With [mainMessage] (the parent JSON from
  /// [createMainMessage]) it is a thread reply; [showInChannel] also posts it
  /// to the room ("Also send to room").
  Future<void> sendText(
    String roomJid,
    String text, {
    String? mainMessage,
    bool showInChannel = false,
  }) async {
    final user = state.value.user;
    if (user == null || text.trim().isEmpty) return;
    final isReply = (mainMessage ?? '').isNotEmpty;
    if (!isReply) clearJumpWindow(roomJid);
    final messageId = _newMessageId('send-text-message');
    final now = DateTime.now().millisecondsSinceEpoch;
    final pending = ChatMessage(
      id: messageId,
      xmppId: messageId,
      roomJid: roomJid,
      text: text,
      user: user,
      createdAtMs: now,
      timestamp: now,
      pending: true,
      isReply: isReply,
      showInChannel: !isReply || showInChannel,
      mainMessage: isReply ? mainMessage : null,
      langSource: _langSource,
    );
    _appendPendingMessage(pending);
    _pendingHeap.add(
      _PendingHeapItem.text(
        messageId: messageId,
        roomJid: roomJid,
        text: text,
        isReply: isReply,
        showInChannel: showInChannel,
        mainMessage: mainMessage ?? '',
      ),
    );
    _setPendingSendState(messageId, roomJid);
    _armWatchdog(messageId, roomJid, kTextPendingWatchdog);
    promoteRoomHistory(roomJid);
    _enqueueText(
      messageId,
      roomJid,
      text,
      isReply: isReply,
      showInChannel: showInChannel,
      mainMessage: mainMessage ?? '',
    );
  }

  void _enqueueText(
    String messageId,
    String roomJid,
    String text, {
    bool isReply = false,
    bool showInChannel = false,
    String mainMessage = '',
  }) {
    unawaited(_sendQueue.enqueue(
      id: messageId,
      roomJid: roomJid,
      task: () async {
        final xmpp = _xmpp;
        if (xmpp == null) return false;
        await xmpp.sendText(
          roomJid: roomJid,
          messageId: messageId,
          text: text,
          isReply: isReply,
          showInChannel: showInChannel,
          mainMessage: mainMessage,
          langSource: _langSource ?? 'en',
        );
        return true;
      },
    ));
  }

  Future<void> sendMedia(
    String roomJid, {
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) {
    return sendMediaFiles(
      roomJid,
      files: <MediaFileInput>[
        MediaFileInput(bytes: bytes, filename: filename, mimeType: mimeType),
      ],
    );
  }

  void _enqueueMedia(
    String messageId,
    String roomJid,
    String mediaUrl,
    String mimeType,
    Map<String, dynamic> file, {
    List<Map<String, dynamic>> files = const <Map<String, dynamic>>[],
    String? caption,
  }) {
    unawaited(_sendQueue.enqueue(
      id: messageId,
      roomJid: roomJid,
      task: () async {
        final xmpp = _xmpp;
        if (xmpp == null) return false;
        await xmpp.sendMedia(
          roomJid: roomJid,
          messageId: messageId,
          mediaUrl: mediaUrl,
          mimeType: mimeType,
          file: file,
          files: files,
          caption: caption,
        );
        return true;
      },
    ));
  }

  /// Re-sends a failed message with the same id, like web resendMessage
  /// with reuseId, so a late echo of the first attempt still reconciles.
  Future<void> retryMessage(String roomJid, String messageId) async {
    final item = _pendingHeap
        .where((e) => e.messageId == messageId && e.roomJid == roomJid)
        .firstOrNull;
    if (item == null) return;
    _updateMessage(
        roomJid, messageId, (m) => m.copyWith(failed: false, pending: true));
    _armWatchdog(
      messageId,
      roomJid,
      item.kind == _HeapKind.text
          ? kTextPendingWatchdog
          : kMediaPendingWatchdog,
    );
    if (item.kind == _HeapKind.text) {
      _enqueueText(
        messageId,
        roomJid,
        item.text ?? '',
        isReply: item.isReply,
        showInChannel: item.showInChannel,
        mainMessage: item.mainMessage,
      );
    } else {
      _enqueueMedia(
        messageId,
        roomJid,
        item.mediaUrl ?? '',
        item.mimeType ?? 'application/octet-stream',
        item.file ?? const <String, dynamic>{},
        files: item.files,
        caption: item.caption,
      );
    }
  }

  void _armWatchdog(String messageId, String roomJid, Duration timeout) {
    _pendingWatchdogs.remove(messageId)?.cancel();
    _pendingWatchdogs[messageId] = Timer(timeout, () {
      _pendingWatchdogs.remove(messageId);
      _updateMessage(roomJid, messageId, (m) {
        if (!m.pending) return m;
        return m.copyWith(pending: false, failed: true);
      });
      _recalculateUnread();
    });
  }

  Future<void> setTyping(String roomJid, bool isTyping) async {
    if (config.disableTypingIndicator) return;
    await _xmpp?.sendTyping(roomJid: roomJid, isTyping: isTyping);
    _typingStopTimer?.cancel();
    if (isTyping) {
      _typingStopTimer = Timer(const Duration(milliseconds: 800), () {
        _xmpp?.sendTyping(roomJid: roomJid, isTyping: false);
      });
    }
  }

  /// Loads one MAM page. Without [beforeId] it fetches the newest page.
  Future<MamPage> loadHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
    HistorySource source = HistorySource.normal,
  }) async {
    final epoch = _roomEpoch[roomJid] ?? 0;
    final hadMessages = _roomHasArchivedMessages(roomJid);
    var page = const MamPage();
    final task = HistoryTask(
      id: 'history-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(99999)}',
      roomJid: roomJid,
      source: source,
      epoch: epoch,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      run: () async {
        final xmpp = _xmpp;
        if (xmpp == null) return;
        page = await xmpp.requestHistory(
          roomJid: roomJid,
          max: max,
          beforeId: beforeId,
        );
      },
      completer: Completer<void>(),
    );
    await _historyQueue.enqueue(task);
    _applyHistoryPage(
      roomJid,
      page,
      beforeId: beforeId,
      hadMessages: hadMessages,
    );
    return page;
  }

  /// Loads the page before the oldest archived message of [roomJid]
  /// (scroll-to-top). Returns false when the archive is exhausted or a load
  /// is already running.
  Future<bool> loadOlderMessages(String roomJid, {int max = 30}) async {
    final room = state.value.rooms.where((r) => r.jid == roomJid).firstOrNull;
    if (room?.historyComplete == true) return false;
    if (!_historyInFlight.add(roomJid)) return false;
    try {
      // The server's own cursor (older of it and the oldest loaded row), so a
      // page made only of reactions or receipts does not stall paging.
      final oldest = _olderAnchor(roomJid);
      final page = await loadHistory(
        roomJid: roomJid,
        max: max,
        beforeId: oldest,
        source: HistorySource.active,
      );
      if (oldest == null && page.complete) {
        _updateRoom(roomJid, (r) => r.copyWith(historyComplete: true));
      }
      // A page that does not move the cursor would be asked for again forever.
      if (!page.complete &&
          !page.error &&
          !page.timedOut &&
          oldest != null &&
          !historyPageProgressed(anchor: oldest, first: page.first)) {
        return false;
      }
      return !page.complete && !page.error;
    } finally {
      _historyInFlight.remove(roomJid);
    }
  }

  Future<void> markRoomViewed(String roomJid, {int? timestampMs}) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final map = <String, List<ChatMessage>>{...state.value.messagesByRoom};
    final roomMessages = map[roomJid] ?? const <ChatMessage>[];
    map[roomJid] = _unreadService.normalizeDelimiterPosition(
      roomMessages,
      ts,
      roomJid,
    );

    final updatedRooms = state.value.rooms.map((room) {
      if (room.jid != roomJid) return room;
      return room.copyWith(
        lastViewedTimestamp: ts,
        unreadCount: 0,
        unreadCapped: false,
      );
    }).toList();

    state.value = state.value.copyWith(
      messagesByRoom: map,
      rooms: updatedRooms,
    );
    if (config.disableLastRead != true) {
      await _privateStoreSync.write(_xmpp, roomJid: roomJid, timestamp: ts);
    }
  }

  void promoteRoomHistory(String roomJid) {
    _roomEpoch[roomJid] = (_roomEpoch[roomJid] ?? 0) + 1;
    _historyQueue.promoteRoom(roomJid);
    state.value = state.value.copyWith(
      roomEpoch: Map<String, int>.from(_roomEpoch),
    );
  }

  Future<void> syncPrivateStoreTimestamps() async {
    final timestamps = await _privateStoreSync.read(_xmpp);
    if (timestamps.isEmpty) return;
    final updatedRooms = state.value.rooms.map((room) {
      final ts = timestamps[room.jid];
      if (ts == null || ts <= 0) return room;
      return room.copyWith(lastViewedTimestamp: ts);
    }).toList();
    state.value = state.value.copyWith(rooms: updatedRooms);
    _recalculateUnread();
  }

  Future<void> recoverPendingHeap() async {
    final snapshot = List<_PendingHeapItem>.from(_pendingHeap);
    for (final item in snapshot) {
      if (item.kind == _HeapKind.text) {
        _enqueueText(
          item.messageId,
          item.roomJid,
          item.text ?? '',
          isReply: item.isReply,
          showInChannel: item.showInChannel,
          mainMessage: item.mainMessage,
        );
      } else {
        _enqueueMedia(
          item.messageId,
          item.roomJid,
          item.mediaUrl ?? '',
          item.mimeType ?? 'application/octet-stream',
          item.file ?? const <String, dynamic>{},
          files: item.files,
          caption: item.caption,
        );
      }
    }
  }

  /// Signs out in web order (see [ChatControllerAccount]): push release in
  /// parallel with the read marker flush, XMPP disconnect, stored session
  /// cleared, `config.logout` hooks around it.
  Future<void> logout() => _runLogout();

  /// Called by [ApiClient] when a token refresh failed for good: the
  /// session is gone, so the UI must show the login state.
  Future<void> _onSessionExpired() async {
    _apiClient.auth.stopProactive();
    await _store.clearSession();
    if (_disposed) return;
    await _xmpp?.disconnect();
    _xmpp = null;
    _resetRuntimeState();
    state.value = const ChatComponentState(
      isInitialized: false,
      requiresLogin: true,
      connectionState: ChatConnectionState.offline,
      errorMessage: 'Session expired. Please sign in again.',
    );
  }

  void _resetRuntimeState() {
    _pendingHeap.clear();
    _sendQueue.clear();
    _historyQueue.clear();
    for (final t in _pendingWatchdogs.values) {
      t.cancel();
    }
    _pendingWatchdogs.clear();
    for (final room in _typers.values) {
      for (final entry in room.values) {
        entry.$2.cancel();
      }
    }
    _typers.clear();
    _historyInFlight.clear();
    _disposeMessagingRuntime();
    _disposeJumpRuntime();
    _disposeRoomsRuntime();
    _disposeCallsRuntime();
  }

  void _appendPendingMessage(ChatMessage message) {
    final map = <String, List<ChatMessage>>{...state.value.messagesByRoom};
    final existing = map[message.roomJid] ?? <ChatMessage>[];
    map[message.roomJid] = <ChatMessage>[...existing, message];
    final updatedRooms = state.value.rooms.map((room) {
      if (room.jid != message.roomJid) return room;
      return room.copyWith(pendingMessages: room.pendingMessages + 1);
    }).toList();
    state.value = state.value.copyWith(
      messagesByRoom: map,
      rooms: updatedRooms,
    );
  }

  void _setPendingSendState(String messageId, String roomJid) {
    final pending = <String, String>{...state.value.pendingSendById};
    pending[messageId] = roomJid;
    state.value = state.value.copyWith(pendingSendById: pending);
  }

  void _clearPendingSendState(String messageId) {
    final pending = <String, String>{...state.value.pendingSendById};
    pending.remove(messageId);
    state.value = state.value.copyWith(pendingSendById: pending);
  }

  Future<void> _deliverOnMessageSent(ChatMessage message) async {
    if (_sentCallbackDeliveredFor.contains(message.id)) return;
    _sentCallbackDeliveredFor.add(message.id);
    final callback = config.eventHandlers?.onMessageSent;
    if (callback == null) return;
    await callback(
      ChatMessageSentEvent(
        message: message,
        roomJid: message.roomJid,
        messageId: message.id,
        sentAt: DateTime.now(),
      ),
    );
  }

  void _handleIncomingMessage(ChatMessage incoming) {
    final map = <String, List<ChatMessage>>{...state.value.messagesByRoom};
    final roomMessages = <ChatMessage>[
      ...(map[incoming.roomJid] ?? <ChatMessage>[]),
    ];

    // The same call logged twice (this device's fallback entry and the
    // server's): keep one, the longer (web addRoomMessage callLog.callId).
    final callLogAt = callLogIndexFor(roomMessages, incoming);
    if (callLogAt >= 0 && roomMessages[callLogAt].id != incoming.id) {
      incoming = mergeCallLog(roomMessages.removeAt(callLogAt), incoming);
    }

    // The echo of our own send carries our outer id as xmppId.
    final pendingIndex = incoming.xmppId == null
        ? -1
        : roomMessages.indexWhere(
            (m) => m.xmppId == incoming.xmppId && (m.pending || m.failed),
          );

    ChatMessage? acked;
    if (pendingIndex >= 0) {
      final local = roomMessages[pendingIndex];
      acked = incoming.copyWith(user: local.user);
      roomMessages[pendingIndex] = acked;
      _pendingHeap.removeWhere((item) => item.messageId == local.xmppId);
      _pendingWatchdogs.remove(local.xmppId)?.cancel();
      _clearPendingSendState(local.xmppId!);
    } else {
      final dupIndex = roomMessages.indexWhere(
        (m) =>
            m.id == incoming.id ||
            (incoming.xmppId != null &&
                m.xmppId == incoming.xmppId &&
                !m.pending),
      );
      if (dupIndex >= 0) {
        final existing = roomMessages[dupIndex];
        roomMessages[dupIndex] = incoming.copyWith(
          reactions: existing.reactions.isNotEmpty ? existing.reactions : null,
          isEdited: existing.isEdited ? true : null,
          text: existing.isEdited ? existing.text : null,
        );
      } else {
        roomMessages.add(incoming);
      }
    }
    roomMessages.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    _applyParkedReactions(incoming.roomJid, roomMessages);

    final targetRoom = state.value.rooms.firstWhere(
      (room) => room.jid == incoming.roomJid,
      orElse: () => ChatRoom(jid: incoming.roomJid, title: incoming.roomJid),
    );
    map[incoming.roomJid] = _unreadService.normalizeDelimiterPosition(
      roomMessages,
      targetRoom.lastViewedTimestamp,
      incoming.roomJid,
    );
    state.value = state.value.copyWith(messagesByRoom: map);
    _recalculateUnread();
    if (acked != null) {
      unawaited(_deliverOnMessageSent(acked));
    }
    _afterIncomingMessage(incoming, wasOwnEcho: acked != null);
  }

  void _handleEdit(ParsedEdit edit) {
    _updateMessage(
      edit.roomJid,
      edit.targetId,
      (m) => m.copyWith(text: edit.text, isEdited: true),
    );
  }

  void _handleDelete(ParsedDelete delete) {
    _updateMessage(
      delete.roomJid,
      delete.targetId,
      (m) => m
          .copyWith(isDeleted: true, reactions: const <String, ChatReaction>{}),
    );
    _recalculateUnread();
  }

  void _handleReaction(ParsedReaction event) {
    final loaded = state.value.messagesByRoom[event.roomJid];
    final known = loaded?.any(
          (m) => m.id == event.targetId || m.xmppId == event.targetId,
        ) ??
        false;
    if (!known) {
      _parkReaction(event);
      return;
    }
    _updateMessage(event.roomJid, event.targetId, (m) {
      final current = m.reactions[event.reactor];
      if (current != null && compareReactionTs(event.reaction.ts, current.ts) < 0) {
        return m;
      }
      return m.copyWith(
        reactions: <String, ChatReaction>{
          ...m.reactions,
          event.reactor: event.reaction,
        },
      );
    });
  }

  void _handleTyping(ParsedTyping event) {
    final me = _myLocal;
    if (me.isNotEmpty &&
        (event.nick.toLowerCase() == me ||
            localPart(event.senderJid).toLowerCase() == me)) {
      return;
    }
    final room =
        _typers.putIfAbsent(event.roomJid, () => <String, (String, Timer)>{});
    room.remove(event.nick)?.$2.cancel();
    if (event.composing) {
      final name = event.fullName.trim().split(' ').first;
      room[event.nick] = (
        name.isEmpty ? event.nick : name,
        Timer(kTypingExpiry, () {
          room.remove(event.nick);
          _publishTypers(event.roomJid);
        }),
      );
    }
    _publishTypers(event.roomJid);
  }

  void _publishTypers(String roomJid) {
    final names = (_typers[roomJid] ?? const <String, (String, Timer)>{})
        .values
        .map((e) => e.$1)
        .toList();
    _updateRoom(roomJid, (room) => room.copyWith(composingList: names));
  }

  void _updateRoom(String roomJid, ChatRoom Function(ChatRoom room) update) {
    if (_disposed) return;
    state.value = state.value.copyWith(
      rooms: state.value.rooms
          .map((room) => room.jid == roomJid ? update(room) : room)
          .toList(),
    );
  }

  void _updateMessage(
    String roomJid,
    String messageId,
    ChatMessage Function(ChatMessage message) update,
  ) {
    if (_disposed) return;
    final list = state.value.messagesByRoom[roomJid];
    if (list == null) return;
    var changed = false;
    final next = list.map((m) {
      if (m.id == messageId || m.xmppId == messageId) {
        changed = true;
        return update(m);
      }
      return m;
    }).toList();
    if (!changed) return;
    state.value = state.value.copyWith(
      messagesByRoom: <String, List<ChatMessage>>{
        ...state.value.messagesByRoom,
        roomJid: next,
      },
    );
  }

  void _recalculateUnread() {
    if (_disposed) return;
    final selectedRoomJid = state.value.selectedRoomJid;
    final user = state.value.user;
    final updatedRooms = state.value.rooms.map((room) {
      final messages =
          (state.value.messagesByRoom[room.jid] ?? const <ChatMessage>[])
              .where((m) => !m.isDeleted)
              .toList();
      final unread = _unreadService.computeUnreadForRoom(
        room: room,
        messages: messages,
        activeRoomJid: selectedRoomJid,
        currentUser: user,
      );
      return room.copyWith(
        unreadCount: unread.unread,
        unreadCapped: unread.unreadCapped,
        pendingMessages: messages.where((m) => m.pending).length,
      );
    }).toList();
    state.value = state.value.copyWith(rooms: updatedRooms);
  }

  void _log(ChatLogLevel level, ChatLogCategory category, String message) {
    _emitLog(
      ChatLogEvent(
        level: level,
        category: category,
        message: message,
        timestamp: DateTime.now(),
      ),
    );
  }

  void _emitLog(ChatLogEvent event) {
    if (_logController.isClosed) return;
    _logController.add(event);
  }

  void dispose() {
    _disposed = true;
    _typingStopTimer?.cancel();
    _apiClient.auth.stopProactive();
    _push.dispose();
    _xmpp?.disconnect();
    _resetRuntimeState();
    _logController.close();
    state.dispose();
  }

  /// Sends ONE message carrying every file in [files], in pick order, like
  /// web sendMedia. Files upload [kMediaUploadConcurrency] at a time; the
  /// stanza goes out only once all of them are up, so a failed upload throws
  /// and nothing is sent. [caption] rides on the same message.
  Future<void> sendMediaFiles(
    String roomJid, {
    required List<MediaFileInput> files,
    String? caption,
  }) async {
    if (config.disableMedia == true || files.isEmpty) {
      return;
    }
    final user = state.value.user;
    if (user == null) return;

    final picked = files.take(kMaxAttachmentsPerMessage).toList();
    final results = List<Map<String, dynamic>>.filled(
      picked.length,
      const <String, dynamic>{},
    );
    for (var start = 0; start < picked.length; start += kMediaUploadConcurrency) {
      final end = min(start + kMediaUploadConcurrency, picked.length);
      await Future.wait(<Future<void>>[
        for (var i = start; i < end; i++)
          _mediaUploads
              .uploadFile(
                roomJid: roomJid,
                bytes: picked[i].bytes,
                filename: picked[i].filename,
                mimeType: picked[i].mimeType,
              )
              .then((raw) {
                results[i] = raw;
              }),
      ]);
    }

    final head = results.first;
    final mediaUrl = head['location']?.toString() ?? '';
    if (mediaUrl.isEmpty) {
      throw Exception('Media upload returned empty location');
    }
    final mimeType = picked.first.mimeType;
    final trimmedCaption = caption?.trim() ?? '';

    final messageId = _newMessageId('send-media-message');
    final now = DateTime.now().millisecondsSinceEpoch;
    final pending = ChatMessage(
      id: messageId,
      xmppId: messageId,
      roomJid: roomJid,
      text: 'media',
      user: user,
      createdAtMs: now,
      timestamp: now,
      pending: true,
      isMedia: true,
      mediaUrl: mediaUrl,
      mimeType: mimeType,
      attachments: results.map(attachmentFromUploadResult).toList(),
      data: <String, String>{
        if (trimmedCaption.isNotEmpty) 'caption': trimmedCaption,
      },
    );
    _appendPendingMessage(pending);
    _pendingHeap.add(
      _PendingHeapItem.media(
        messageId: messageId,
        roomJid: roomJid,
        mediaUrl: mediaUrl,
        mimeType: mimeType,
        file: head,
        files: results,
        caption: trimmedCaption.isEmpty ? null : trimmedCaption,
      ),
    );
    _setPendingSendState(messageId, roomJid);
    _armWatchdog(messageId, roomJid, kMediaPendingWatchdog);
    promoteRoomHistory(roomJid);
    _enqueueMedia(
      messageId,
      roomJid,
      mediaUrl,
      mimeType,
      head,
      files: results,
      caption: trimmedCaption.isEmpty ? null : trimmedCaption,
    );
  }

  /// A refresh response carried a new `fileToken`: keep it in secure storage
  /// and in the session user, so secure media re-renders with the fresh `ft`.
  Future<void> _onFileTokenRefreshed(String fileToken) async {
    await _store.setFileToken(fileToken);
    if (_disposed) return;
    final current = state.value.user;
    if (current == null) return;
    state.value = state.value.copyWith(
      user: current.copyWith(fileToken: fileToken),
    );
  }
}
