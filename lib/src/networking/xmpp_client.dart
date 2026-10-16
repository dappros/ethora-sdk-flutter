import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

import '../models/chat_component_config.dart';
import '../models/chat_message.dart';
import '../models/chat_user.dart';
import '../core/chat_component_log.dart';
import '../core/chat_component_state.dart';

typedef XmppMessageCallback = void Function(ChatMessage message);
typedef XmppTypingCallback =
    void Function(String roomJid, List<String> composingUsers);
typedef XmppConnectionCallback = void Function(ChatConnectionState state);

class XmppClient {
  XmppClient({required this.settings, required this.user, required this.log});

  final XmppSettings settings;
  final ChatUser user;
  final void Function(ChatLogEvent event) log;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  bool _manuallyClosed = false;
  int _reconnectAttempts = 0;
  final Map<String, int> _privateStoreTimestamps = <String, int>{};

  XmppMessageCallback? onMessage;
  XmppTypingCallback? onTyping;
  XmppConnectionCallback? onConnectionChanged;
  void Function()? onReconnected;

  ChatConnectionState get state => _state;
  ChatConnectionState _state = ChatConnectionState.offline;

  String _nextId(String prefix) {
    final n = Random().nextInt(999999);
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$n';
  }

  Future<void> connect() async {
    _manuallyClosed = false;
    _setState(ChatConnectionState.connecting);
    try {
      _channel = IOWebSocketChannel.connect(
        Uri.parse(settings.endpoint),
        pingInterval: const Duration(seconds: 25),
      );
      _subscription = _channel!.stream.listen(
        _handleRawStanza,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
      _sendOpenStream();
      _sendAuth();
      _sendGlobalPresence();
      final wasReconnect = _reconnectAttempts > 0;
      _setState(ChatConnectionState.online);
      if (wasReconnect) {
        onReconnected?.call();
      }
    } catch (e) {
      log(
        ChatLogEvent(
          level: ChatLogLevel.error,
          category: ChatLogCategory.xmpp,
          message: 'XMPP connect failed: $e',
          timestamp: DateTime.now(),
        ),
      );
      _setState(ChatConnectionState.error);
      _scheduleReconnect();
    }
  }

  void _setState(ChatConnectionState state) {
    _state = state;
    onConnectionChanged?.call(state);
  }

  void _sendRaw(String stanza) {
    _channel?.sink.add(stanza);
    log(
      ChatLogEvent(
        level: ChatLogLevel.debug,
        category: ChatLogCategory.xmpp,
        message: 'XMPP -> $stanza',
        timestamp: DateTime.now(),
      ),
    );
  }

  void _sendOpenStream() {
    final host = settings.host;
    _sendRaw(
      "<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='$host' version='1.0'/>",
    );
  }

  void _sendAuth() {
    final username =
        user.xmppUsername ?? user.walletAddress ?? user.username ?? '';
    final password = user.xmppPassword ?? '';
    final payload = base64Encode(utf8.encode('\u0000$username\u0000$password'));
    _sendRaw(
      "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>$payload</auth>",
    );
  }

  void _sendGlobalPresence() {
    _sendRaw("<presence id='${_nextId('presence')}'/>");
  }

  Future<void> sendRoomPresence(String roomJid) async {
    final nick =
        user.xmppUsername ?? user.walletAddress ?? user.username ?? 'flutter';
    _sendRaw(
      "<presence to='$roomJid/$nick' id='presenceInRoom'><x xmlns='http://jabber.org/protocol/muc'/></presence>",
    );
  }

  Future<void> sendPresenceToRooms(List<String> roomJids) async {
    for (final roomJid in roomJids) {
      await sendRoomPresence(roomJid);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> requestHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
  }) async {
    final id = _nextId('history');
    final beforeTag = beforeId == null
        ? '<before/>'
        : '<before>$beforeId</before>';
    _sendRaw(
      "<iq to='$roomJid' type='set' id='$id'><query xmlns='urn:xmpp:mam:2' queryid='$id'><set xmlns='http://jabber.org/protocol/rsm'><max>$max</max>$beforeTag</set></query></iq>",
    );
  }

  Future<void> sendText({
    required String roomJid,
    required String messageId,
    required String text,
  }) async {
    _sendRaw(
      "<message id='$messageId' to='$roomJid' type='groupchat'><body>${_xmlEscape(text)}</body></message>",
    );
  }

  Future<void> sendMedia({
    required String roomJid,
    required String messageId,
    required String mediaUrl,
    required String mimeType,
  }) async {
    final filename = mediaUrl.split('/').last;
    _sendRaw(
      "<message id='$messageId' to='$roomJid' type='groupchat'><body>media</body><store xmlns='urn:xmpp:hints'/><data isMediafile='true' location='${_xmlEscape(mediaUrl)}' mimetype='${_xmlEscape(mimeType)}' fileName='${_xmlEscape(filename)}'/></message>",
    );
  }

  Future<void> sendTyping({
    required String roomJid,
    required bool isTyping,
  }) async {
    final tag = isTyping ? 'composing' : 'paused';
    _sendRaw(
      "<message id='${_nextId('typing')}' to='$roomJid' type='groupchat'><$tag xmlns='http://jabber.org/protocol/chatstates'/></message>",
    );
  }

  Future<Map<String, int>> getChatsPrivateStore() async {
    return Map<String, int>.from(_privateStoreTimestamps);
  }

  Future<void> setTimestampToPrivateStore({
    required String chatId,
    required int timestamp,
    List<String>? chats,
  }) async {
    if (chatId.isEmpty || timestamp <= 0) return;
    _privateStoreTimestamps[chatId] = timestamp;
    for (final chat in chats ?? const <String>[]) {
      if (chat.trim().isEmpty) continue;
      _privateStoreTimestamps[chat.trim()] = timestamp;
    }
    final escapedChat = _xmlEscape(chatId);
    final id = _nextId('private-store');
    _sendRaw(
      "<iq type='set' id='$id'><query xmlns='ethora:private-store'><chat id='$escapedChat' ts='$timestamp'/></query></iq>",
    );
  }

  void _handleRawStanza(dynamic raw) {
    final text = raw.toString();
    log(
      ChatLogEvent(
        level: ChatLogLevel.debug,
        category: ChatLogCategory.xmpp,
        message: 'XMPP <- $text',
        timestamp: DateTime.now(),
      ),
    );

    if (!text.trimLeft().startsWith('<')) {
      return;
    }

    XmlDocument? doc;
    try {
      doc = XmlDocument.parse('<root>$text</root>');
    } catch (_) {
      return;
    }
    final nodes = doc.rootElement.children.whereType<XmlElement>();
    for (final node in nodes) {
      if (node.name.local == 'message') {
        _handleMessage(node);
      }
    }
  }

  void _handleMessage(XmlElement node) {
    final resultNode =
        _findDirectChild(node, 'result', xmlns: 'urn:xmpp:mam:2') ??
        _findDirectChild(node, 'result');
    if (resultNode != null) {
      _handleMamResultMessage(node, resultNode);
      return;
    }

    final bodyNode = _findDirectChild(node, 'body');
    final roomJid = node.getAttribute('from')?.split('/').first ?? '';
    if (roomJid.isNotEmpty) {
      final body = bodyNode?.innerText ?? '';
      final mediaFromData = _tryParseMediaData(_findDirectChild(node, 'data'));
      final messageId = node.getAttribute('id') ?? _nextId('incoming');
      final from = node.getAttribute('from') ?? '';
      final senderName = from.contains('/') ? from.split('/').last : 'Unknown';
      final parsed = mediaFromData ?? _tryParseMedia(body);
      if (body.trim().isEmpty && parsed == null) {
        return;
      }
      onMessage?.call(
        ChatMessage(
          id: messageId,
          roomJid: roomJid,
          text: parsed?.$1 ?? body.trim(),
          user: ChatUser(username: senderName, xmppUsername: senderName),
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          pending: false,
          isMedia: parsed != null,
          mediaUrl: parsed?.$2,
          mimeType: parsed?.$3,
        ),
      );
    }

    final hasComposing = node.findElements('composing').isNotEmpty;
    final hasPaused = node.findElements('paused').isNotEmpty;
    if ((hasComposing || hasPaused) && roomJid.isNotEmpty) {
      final from = node.getAttribute('from') ?? '';
      final senderName = from.contains('/') ? from.split('/').last : 'Unknown';
      onTyping?.call(roomJid, hasComposing ? <String>[senderName] : <String>[]);
    }
  }

  void _handleMamResultMessage(
    XmlElement stanzaMessage,
    XmlElement resultNode,
  ) {
    final forwarded =
        _findDirectChild(
          resultNode,
          'forwarded',
          xmlns: 'urn:xmpp:forward:0',
        ) ??
        _findDirectChild(resultNode, 'forwarded');
    final historyMessage = forwarded == null
        ? null
        : _findDirectChild(forwarded, 'message');
    if (historyMessage == null) {
      return;
    }
    final bodyNode = _findDirectChild(historyMessage, 'body');

    final body = bodyNode?.innerText ?? '';
    final roomJid = historyMessage.getAttribute('from')?.split('/').first ?? '';
    if (roomJid.isEmpty) {
      return;
    }
    final from = historyMessage.getAttribute('from') ?? '';
    final senderName = from.contains('/') ? from.split('/').last : 'Unknown';
    final messageId =
        historyMessage.getAttribute('id') ??
        stanzaMessage.getAttribute('id') ??
        _nextId('history-msg');
    final mediaFromData = _tryParseMediaData(
      _findDirectChild(historyMessage, 'data'),
    );
    final parsed = mediaFromData ?? _tryParseMedia(body);
    if (body.trim().isEmpty && parsed == null) {
      return;
    }
    onMessage?.call(
      ChatMessage(
        id: messageId,
        roomJid: roomJid,
        text: parsed?.$1 ?? body.trim(),
        user: ChatUser(username: senderName, xmppUsername: senderName),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        pending: false,
        isMedia: parsed != null,
        mediaUrl: parsed?.$2,
        mimeType: parsed?.$3,
      ),
    );
  }

  XmlElement? _findDirectChild(
    XmlElement parent,
    String localName, {
    String? xmlns,
  }) {
    for (final child in parent.children.whereType<XmlElement>()) {
      final nameMatches = child.name.local == localName;
      if (!nameMatches) {
        continue;
      }
      if (xmlns == null ||
          child.namespaceUri == xmlns ||
          child.getAttribute('xmlns') == xmlns) {
        return child;
      }
    }
    return null;
  }

  (String, String, String)? _tryParseMediaData(XmlElement? dataNode) {
    if (dataNode == null) {
      return null;
    }
    final location = dataNode.getAttribute('location');
    final mime = dataNode.getAttribute('mimetype');
    if (location == null || location.isEmpty || mime == null || mime.isEmpty) {
      return null;
    }
    return ('[media] $location', location, mime);
  }

  (String, String, String)? _tryParseMedia(String body) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      final location = map['location']?.toString();
      final mime = map['mimetype']?.toString();
      if (location == null || mime == null) {
        return null;
      }
      return ('[media] $location', location, mime);
    } catch (_) {
      return null;
    }
  }

  String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  void _scheduleReconnect() {
    if (_manuallyClosed) {
      return;
    }
    _setState(ChatConnectionState.error);
    _reconnectTimer?.cancel();
    _reconnectAttempts += 1;
    final delaySeconds = _reconnectAttempts > 5 ? 15 : _reconnectAttempts * 2;
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      connect();
    });
  }

  Future<void> disconnect() async {
    _manuallyClosed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _subscription = null;
    _setState(ChatConnectionState.offline);
  }
}
