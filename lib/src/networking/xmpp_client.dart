import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

import '../core/chat_component_log.dart';
import '../core/chat_component_state.dart';
import '../models/chat_component_config.dart';
import '../models/chat_message.dart';
import '../models/chat_user.dart';
import '../models/media_attachment.dart';
import 'stanza_parser.dart';

typedef XmppMessageCallback = void Function(ChatMessage message);
typedef XmppTypingCallback = void Function(ParsedTyping typing);
typedef XmppConnectionCallback = void Function(ChatConnectionState state);

/// Minimal duplex text transport so the client can be driven by a fake
/// socket in tests.
abstract class XmppTransport {
  Stream<String> get incoming;
  void send(String frame);
  Future<void> close();
}

class WebSocketXmppTransport implements XmppTransport {
  WebSocketXmppTransport(Uri endpoint)
      : _channel = IOWebSocketChannel.connect(
          endpoint,
          protocols: const <String>['xmpp'],
          pingInterval: const Duration(seconds: 25),
        );

  final WebSocketChannel _channel;

  @override
  Stream<String> get incoming =>
      _channel.stream.map((dynamic frame) => frame.toString());

  @override
  void send(String frame) => _channel.sink.add(frame);

  @override
  Future<void> close() async => _channel.sink.close();
}

typedef XmppTransportFactory = XmppTransport Function(Uri endpoint);

/// One MAM page answer (`<fin>`), like web fetchHistoryPage.
class MamPage {
  const MamPage({
    this.complete = false,
    this.first,
    this.last,
    this.count = 0,
    this.error = false,
    this.timedOut = false,
    this.messages = const <ChatMessage>[],
    this.modifiers = const <ParsedStanza>[],
  });

  final bool complete;
  final String? first;
  final String? last;

  /// Number of `<result>` rows that arrived for this query.
  final int count;
  final bool error;
  final bool timedOut;

  /// The archived rows of this page, oldest first, as received.
  final List<ChatMessage> messages;

  /// Edits, deletes and reactions that arrived with a silent page
  /// (`deliver: false`); a delivering page applies them through the
  /// callbacks instead.
  final List<ParsedStanza> modifiers;
}

class XmppAuthException implements Exception {
  XmppAuthException(this.condition);
  final String condition;
  @override
  String toString() => 'XMPP auth failed: $condition';
}

const _nsFraming = 'urn:ietf:params:xml:ns:xmpp-framing';
const _nsSasl = 'urn:ietf:params:xml:ns:xmpp-sasl';
const _nsBind = 'urn:ietf:params:xml:ns:xmpp-bind';
const _nsSession = 'urn:ietf:params:xml:ns:xmpp-session';

class XmppClient {
  XmppClient({
    required this.settings,
    required this.user,
    required this.log,
    XmppTransportFactory? transportFactory,
  }) : _transportFactory = transportFactory ?? WebSocketXmppTransport.new;

  final XmppSettings settings;

  /// The session user. Not final: [updateXmppPassword] swaps the SASL
  /// password after a credential recovery.
  ChatUser user;
  final void Function(ChatLogEvent event) log;
  final XmppTransportFactory _transportFactory;

  XmppTransport? _transport;
  StreamSubscription<String>? _subscription;
  Timer? _reconnectTimer;
  Timer? _keepAliveTimer;
  Completer<void>? _onlineCompleter;
  bool _manuallyClosed = false;
  bool _authenticated = false;
  bool _hasEverBeenOnline = false;
  int _reconnectAttempts = 0;
  int _seq = 0;
  String? _boundJid;
  final String _resource = 'flutter-${Random().nextInt(1 << 32)}';
  final Map<String, Completer<XmlElement>> _pendingIq =
      <String, Completer<XmlElement>>{};
  final Map<String, List<ChatMessage>> _mamRows = <String, List<ChatMessage>>{};
  final Set<String> _mamSilent = <String>{};
  final Map<String, List<ParsedStanza>> _mamModifiers =
      <String, List<ParsedStanza>>{};
  final Map<String, int> _privateStoreTimestamps = <String, int>{};

  XmppMessageCallback? onMessage;
  XmppTypingCallback? onTyping;
  void Function(ParsedEdit edit)? onEdit;
  void Function(ParsedDelete delete)? onDelete;
  void Function(ParsedReaction reaction)? onReaction;
  void Function(ParsedReceipt receipt)? onReceipt;
  void Function(ParsedDisplayed displayed)? onDisplayed;
  XmppConnectionCallback? onConnectionChanged;
  void Function()? onReconnected;
  void Function(XmppAuthException error)? onAuthFailed;
  void Function(ParsedEthoraEvent event)? onEthoraEvent;
  void Function(ParsedMembership membership)? onMembership;
  void Function(ParsedPresence presence)? onPresence;

  ChatConnectionState get state => _state;
  ChatConnectionState _state = ChatConnectionState.offline;

  /// Full JID bound by the server, null until online.
  String? get boundJid => _boundJid;

  String get username =>
      user.xmppUsername ?? user.walletAddress ?? user.username ?? '';

  /// Replaces the SASL password used by the next [connect] (credential
  /// recovery after `not-authorized`).
  void updateXmppPassword(String password) {
    user = user.copyWith(xmppPassword: password);
  }

  String _nextId(String prefix) {
    _seq += 1;
    return '$prefix:${DateTime.now().millisecondsSinceEpoch}:$_seq';
  }

  Future<void> connect() async {
    _manuallyClosed = false;
    _reconnectTimer?.cancel();
    await _closeTransport();
    _authenticated = false;
    _boundJid = null;
    _setState(ChatConnectionState.connecting);
    final completer = Completer<void>();
    _onlineCompleter = completer;
    try {
      final transport = _transportFactory(Uri.parse(settings.endpoint));
      _transport = transport;
      _subscription = transport.incoming.listen(
        _handleFrame,
        onError: (Object _) => _handleTransportClosed(),
        onDone: _handleTransportClosed,
      );
      _sendOpenStream();
      await completer.future.timeout(const Duration(seconds: 15));
    } on XmppAuthException catch (e) {
      _setState(ChatConnectionState.error);
      onAuthFailed?.call(e);
    } catch (e) {
      _log(ChatLogLevel.error, 'XMPP connect failed: $e');
      _setState(ChatConnectionState.error);
      _scheduleReconnect();
    }
  }

  void _setState(ChatConnectionState state) {
    _state = state;
    onConnectionChanged?.call(state);
  }

  void _log(ChatLogLevel level, String message) {
    log(
      ChatLogEvent(
        level: level,
        category: ChatLogCategory.xmpp,
        message: message,
        timestamp: DateTime.now(),
      ),
    );
  }

  void _sendRaw(String stanza) {
    final transport = _transport;
    if (transport == null) {
      throw StateError('xmpp_not_connected');
    }
    transport.send(stanza);
    // Never log credentials: the SASL payload is base64 of user+password.
    final safe = stanza.startsWith('<auth ')
        ? '<auth mechanism="PLAIN">[redacted]</auth>'
        : stanza;
    _log(ChatLogLevel.debug, 'XMPP -> $safe');
  }

  bool _trySend(String stanza) {
    try {
      _sendRaw(stanza);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _sendOpenStream() {
    _sendRaw(
      '<open xmlns="$_nsFraming" to="${xmlEscape(settings.host)}" version="1.0"/>',
    );
  }

  void _sendAuth() {
    final payload = base64Encode(
        utf8.encode('\u0000$username\u0000${user.xmppPassword ?? ''}'));
    _sendRaw('<auth xmlns="$_nsSasl" mechanism="PLAIN">$payload</auth>');
  }

  void _handleFrame(String text) {
    _log(ChatLogLevel.debug, 'XMPP <- $text');
    final trimmed = text.trimLeft();
    if (!trimmed.startsWith('<')) return;
    XmlDocument doc;
    try {
      doc = XmlDocument.parse('<root>$text</root>');
    } catch (_) {
      return;
    }
    for (final node in doc.rootElement.childElements) {
      _handleElement(node);
    }
  }

  void _handleElement(XmlElement node) {
    switch (node.name.local) {
      case 'features':
        _handleFeatures(node);
      case 'success':
        _authenticated = true;
        _sendOpenStream();
      case 'failure':
        final condition = node.childElements.isEmpty
            ? 'unknown'
            : node.childElements.first.name.local;
        _manuallyClosed = true;
        final completer = _onlineCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(XmppAuthException(condition));
        } else {
          _setState(ChatConnectionState.error);
          onAuthFailed?.call(XmppAuthException(condition));
        }
      case 'close':
        _handleTransportClosed();
      case 'iq':
        _handleIq(node);
      case 'message':
        _handleMessage(node);
      case 'presence':
        final presence = parsePresenceStanza(node);
        if (presence != null) onPresence?.call(presence);
      default:
        break;
    }
  }

  void _handleFeatures(XmlElement features) {
    if (!_authenticated) {
      _sendAuth();
      return;
    }
    if (childOf(features, 'bind') != null) {
      final id = _nextId('bind');
      _sendIq(
        id,
        '<iq type="set" id="$id"><bind xmlns="$_nsBind"><resource>$_resource</resource></bind></iq>',
      ).then(_onBound, onError: (Object e) {
        final completer = _onlineCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(e);
        }
      });
    }
  }

  Future<void> _onBound(XmlElement result) async {
    _boundJid = childOf(childOf(result, 'bind'), 'jid')?.innerText;
    final sessionId = _nextId('session');
    // Optional on modern servers; never block going online on it.
    unawaited(
      _sendIq(
        sessionId,
        '<iq type="set" id="$sessionId"><session xmlns="$_nsSession"/></iq>',
        timeout: const Duration(seconds: 5),
      ).catchError((Object _) => XmlElement(XmlName('iq'))),
    );
    _sendRaw('<presence/>');
    final wasReconnect = _hasEverBeenOnline;
    _hasEverBeenOnline = true;
    _reconnectAttempts = 0;
    _startKeepAlive();
    _setState(ChatConnectionState.online);
    final completer = _onlineCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    if (wasReconnect) onReconnected?.call();
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_state != ChatConnectionState.online) return;
      final id = _nextId('ping');
      _trySend(
        '<iq type="get" id="$id" to="${xmlEscape(settings.host)}"><ping xmlns="urn:xmpp:ping"/></iq>',
      );
    });
  }

  void _handleIq(XmlElement iq) {
    final id = iq.getAttribute('id') ?? '';
    final type = iq.getAttribute('type');
    if (type == 'get' && childOf(iq, 'ping') != null) {
      final from = iq.getAttribute('from');
      _trySend(
        '<iq type="result" id="${xmlEscape(id)}"${from == null ? '' : ' to="${xmlEscape(from)}"'}/>',
      );
      return;
    }
    final pending = _pendingIq.remove(id);
    if (pending != null && !pending.isCompleted) {
      if (type == 'error') {
        pending.completeError(StateError('iq_error:$id'));
      } else {
        pending.complete(iq);
      }
    }
  }

  Future<XmlElement> _sendIq(
    String id,
    String stanza, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final completer = Completer<XmlElement>();
    _pendingIq[id] = completer;
    if (!_trySend(stanza)) {
      _pendingIq.remove(id);
      return Future<XmlElement>.error(StateError('xmpp_not_connected'));
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingIq.remove(id);
        throw TimeoutException('iq_timeout:$id');
      },
    );
  }

  /// Feature modules (calls, push) that need raw stanzas register here. Each
  /// sees every incoming `<message>` before the chat pipeline; returning true
  /// consumes it (the chat pipeline never sees it).
  final List<bool Function(XmlElement message)> messageInterceptors =
      <bool Function(XmlElement message)>[];

  /// Sends a pre-built stanza. Returns false when the socket is not open.
  bool sendStanza(String stanza) => _trySend(stanza);

  /// Sends an IQ built by the caller and resolves with the result stanza
  /// (an IQ error completes with an error). [id] must be the IQ's own id.
  Future<XmlElement> sendIq(
    String id,
    String stanza, {
    Duration timeout = const Duration(seconds: 10),
  }) =>
      _sendIq(id, stanza, timeout: timeout);

  /// A unique stanza id: `prefix:ms:seq`.
  String nextStanzaId(String prefix) => _nextId(prefix);

  void _handleMessage(XmlElement node) {
    for (final interceptor
        in List<bool Function(XmlElement message)>.of(messageInterceptors)) {
      if (interceptor(node)) return;
    }
    final membership = parseMembershipStanza(node);
    if (membership != null) onMembership?.call(membership);
    final ethoraEvent = parseEthoraEventStanza(node);
    if (ethoraEvent != null) {
      onEthoraEvent?.call(ethoraEvent);
      return;
    }
    final parsed = parseMessageStanza(node);
    if (parsed == null) return;
    // A silent window query keeps its edits, deletes and reactions for the
    // caller; they must not reach the live list.
    if (_mamSilent.isNotEmpty && parsed is! ParsedChatMessage) {
      final silentId = childOf(node, 'result')?.getAttribute('queryid');
      if (silentId != null && _mamSilent.contains(silentId)) {
        if (parsed is ParsedEdit ||
            parsed is ParsedDelete ||
            parsed is ParsedReaction) {
          _mamModifiers[silentId]?.add(parsed);
        }
        return;
      }
    }
    switch (parsed) {
      case ParsedChatMessage(:final message, :final queryId):
        final rows = queryId == null ? null : _mamRows[queryId];
        if (rows != null) {
          rows.add(message);
          // A silent window query keeps its rows for the caller and never
          // writes them into the live list.
          if (_mamSilent.contains(queryId)) return;
        } else if (queryId != null && _mamSilent.contains(queryId)) {
          // A late row of a timed-out window query: still not for the list.
          return;
        }
        onMessage?.call(message);
      case ParsedEdit():
        onEdit?.call(parsed);
      case ParsedDelete():
        onDelete?.call(parsed);
      case ParsedReaction():
        onReaction?.call(parsed);
      case ParsedReceipt():
        onReceipt?.call(parsed);
      case ParsedDisplayed():
        onDisplayed?.call(parsed);
      case ParsedTyping():
        onTyping?.call(parsed);
    }
  }

  /// Joins a MUC room like web presenceInRoom (no history replay; history
  /// comes from MAM).
  Future<void> sendRoomPresence(String roomJid) async {
    final id = _nextId('presenceInRoom');
    _trySend(
      '<presence to="${xmlEscape('$roomJid/$username')}" id="$id">'
      '<x xmlns="http://jabber.org/protocol/muc"><history maxstanzas="0"/></x>'
      '</presence>',
    );
  }

  Future<void> sendPresenceToRooms(List<String> roomJids) async {
    for (final roomJid in roomJids) {
      await sendRoomPresence(roomJid);
    }
  }

  /// One MAM page. [beforeId] / [afterId] are archive ids (exclusive). [start]
  /// and [end] are ISO instants for a time-range query (web jump lookup). With
  /// [deliver] false the rows are returned in [MamPage.messages] only. An IQ
  /// error is an empty page (a fresh room answers with an error), like web.
  Future<MamPage> requestHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
    String? afterId,
    String? start,
    String? end,
    bool deliver = true,
  }) async {
    final id = _nextId('get-history');
    final timeRange = start != null || end != null;
    final cursor = afterId != null
        ? '<after>${xmlEscape(afterId)}</after>'
        : beforeId != null
            ? '<before>${xmlEscape(beforeId)}</before>'
            : timeRange
                ? ''
                : '<before/>';
    final form = !timeRange
        ? ''
        : '<x xmlns="jabber:x:data" type="submit">'
            '<field var="FORM_TYPE" type="hidden"><value>urn:xmpp:mam:2</value></field>'
            '${start == null ? '' : '<field var="start"><value>${xmlEscape(start)}</value></field>'}'
            '${end == null ? '' : '<field var="end"><value>${xmlEscape(end)}</value></field>'}'
            '</x>';
    var keepSilent = false;
    _mamRows[id] = <ChatMessage>[];
    if (!deliver) {
      _mamSilent.add(id);
      _mamModifiers[id] = <ParsedStanza>[];
    }
    try {
      final iq = await _sendIq(
        id,
        '<iq type="set" to="${xmlEscape(roomJid)}" id="$id">'
        '<query xmlns="urn:xmpp:mam:2" queryid="$id">$form'
        '<set xmlns="http://jabber.org/protocol/rsm"><max>$max</max>$cursor</set>'
        '</query></iq>',
      );
      final fin = childOf(iq, 'fin');
      final set = childOf(fin, 'set');
      final rows = List<ChatMessage>.of(_mamRows[id] ?? const <ChatMessage>[]);
      final first = childOf(set, 'first')?.innerText.trim();
      final last = childOf(set, 'last')?.innerText.trim();
      return MamPage(
        complete: fin?.getAttribute('complete') == 'true',
        first: first == null || first.isEmpty ? null : first,
        last: last == null || last.isEmpty ? null : last,
        count: rows.length,
        messages: rows,
        modifiers: List<ParsedStanza>.of(
          _mamModifiers[id] ?? const <ParsedStanza>[],
        ),
      );
    } on TimeoutException {
      keepSilent = !deliver;
      final rows = List<ChatMessage>.of(_mamRows[id] ?? const <ChatMessage>[]);
      return MamPage(count: rows.length, timedOut: true, messages: rows);
    } catch (_) {
      final rows = List<ChatMessage>.of(_mamRows[id] ?? const <ChatMessage>[]);
      return MamPage(count: rows.length, error: true, messages: rows);
    } finally {
      _mamRows.remove(id);
      if (keepSilent) {
        // The server may still be streaming this page: swallow its late rows.
        Timer(const Duration(seconds: 15), () {
          _mamSilent.remove(id);
          _mamModifiers.remove(id);
        });
      } else {
        _mamSilent.remove(id);
        _mamModifiers.remove(id);
      }
    }
  }

  /// Text message exactly like web sendTextMessageWithTranslateTag.
  Future<void> sendText({
    required String roomJid,
    required String messageId,
    required String text,
    bool isReply = false,
    bool showInChannel = false,
    String mainMessage = '',
    String langSource = 'en',
  }) async {
    final attrs = <String, String>{
      'roomJID': roomJid,
      'firstName': user.firstName ?? '',
      'lastName': user.lastName ?? '',
      'photo': user.photoUrl ?? '',
      'walletAddress': user.walletAddress ?? '',
      'notDisplayedValue': '',
      'isReply': '$isReply',
      'showInChannel': '$showInChannel',
      'mainMessage': mainMessage,
      'devServer': settings.endpoint,
      'userMessage': text,
      'push': 'true',
    };
    _sendRaw(
      '<message to="${xmlEscape(roomJid)}" type="groupchat" id="${xmlEscape(messageId)}">'
      '${_dataElement(attrs)}'
      '<body>${xmlEscape(text)}</body>'
      '<translate source="${xmlEscape(langSource)}"/>'
      '</message>',
    );
  }

  /// Media message like web sendMediaMessage. [files] is the upload
  /// `results` in the order the user picked them; with no [files], [file]
  /// is the one upload result. The flat fields describe files[0]; a message
  /// with more than one file also carries the `attachments` JSON attribute.
  /// A non-empty [caption] rides on <data> as `caption`.
  Future<void> sendMedia({
    required String roomJid,
    required String messageId,
    required String mediaUrl,
    required String mimeType,
    Map<String, dynamic> file = const <String, dynamic>{},
    List<Map<String, dynamic>> files = const <Map<String, dynamic>>[],
    String? caption,
  }) async {
    final list = files.isEmpty ? <Map<String, dynamic>>[file] : files;
    final head = list.first;
    String f(String key) => head[key]?.toString() ?? '';
    final attrs = <String, String>{
      'senderJID': _boundJid ?? '',
      'senderFirstName': user.firstName ?? '',
      'senderLastName': user.lastName ?? '',
      'senderWalletAddress': user.walletAddress ?? '',
      'tokenAmount': '0',
      'receiverMessageId': '0',
      'mucname': localPart(roomJid),
      'photoURL': user.photoUrl ?? '',
      'isMediafile': 'true',
      'createdAt': f('createdAt'),
      'expiresAt': f('expiresAt'),
      'fileName': head['filename']?.toString() ?? mediaUrl.split('/').last,
      'isVisible': f('isVisible'),
      'location': mediaUrl,
      'locationPreview': f('locationPreview'),
      'mimetype': mimeType,
      'originalName': f('originalname'),
      'ownerKey': f('ownerKey'),
      'size': f('size'),
      'duration': f('duration'),
      'updatedAt': f('updatedAt'),
      'userId': f('userId'),
      'waveForm': '',
      'attachmentId': f('_id'),
      'isReply': 'false',
      'showInChannel': 'false',
      'mainMessage': '',
      'roomJid': roomJid,
      'push': 'true',
    };
    if (list.length > 1) {
      attrs['attachments'] = serializeAttachments(
        list.map(attachmentFromUploadResult).toList(),
      );
    }
    final trimmedCaption = caption?.trim() ?? '';
    if (trimmedCaption.isNotEmpty) {
      attrs['caption'] = trimmedCaption;
    }
    final from = _boundJid == null ? '' : ' from="${xmlEscape(_boundJid!)}"';
    _sendRaw(
      '<message id="${xmlEscape(messageId)}" type="groupchat"$from to="${xmlEscape(roomJid)}">'
      '<body>media</body><store xmlns="urn:xmpp:hints"/>'
      '${_dataElement(attrs)}'
      '</message>',
    );
  }

  String get _fromAttr =>
      _boundJid == null ? '' : ' from="${xmlEscape(_boundJid!)}"';

  /// Reactions like web sendMessageReaction: [reactions] is the FULL new set
  /// of my shortcodes on [messageId] (archive id), an empty list removes all.
  Future<void> sendReaction({
    required String roomJid,
    required String messageId,
    required List<String> reactions,
  }) async {
    final id = 'message-reaction:${DateTime.now().millisecondsSinceEpoch}';
    final jid = xmlEscape(_boundJid ?? '');
    _sendRaw(
      '<message id="$id" type="groupchat"$_fromAttr to="${xmlEscape(roomJid)}">'
      '<reactions id="${xmlEscape(messageId)}" from="$jid" xmlns="urn:xmpp:reactions:0">'
      '${reactions.map((r) => '<reaction>${xmlEscape(r)}</reaction>').join()}'
      '</reactions>'
      '<data senderFirstName="${xmlEscape(user.firstName ?? '')}" senderLastName="${xmlEscape(user.lastName ?? '')}"/>'
      '<store xmlns="urn:xmpp:hints"/>'
      '</message>',
    );
  }

  /// Edit like web editMessage: the new text is an attribute of `<replace>`.
  Future<void> sendEdit({
    required String roomJid,
    required String messageId,
    required String text,
  }) async {
    final id = 'edit-message-${DateTime.now().millisecondsSinceEpoch}';
    _sendRaw(
      '<message to="${xmlEscape(roomJid)}" type="groupchat" id="$id">'
      '<replace id="${xmlEscape(messageId)}" text="${xmlEscape(text)}"/>'
      '</message>',
    );
  }

  /// Delete like web deleteMessage (fixed id and a dummy body).
  Future<void> sendDelete({
    required String roomJid,
    required String messageId,
  }) async {
    _sendRaw(
      '<message$_fromAttr to="${xmlEscape(roomJid)}" id="deleteMessageStanza" type="groupchat">'
      '<body>wow</body>'
      '<delete id="${xmlEscape(messageId)}"/>'
      '</message>',
    );
  }

  /// XEP-0184 delivery receipt broadcast to the room (web
  /// sendReceivedReceipt). The real reader travels in `<received from>`.
  void sendReceivedReceipt({
    required String roomJid,
    required String messageId,
  }) {
    final id = 'message-received:${DateTime.now().millisecondsSinceEpoch}';
    _trySend(
      '<message id="$id" type="groupchat"$_fromAttr to="${xmlEscape(roomJid)}">'
      '<received xmlns="urn:xmpp:receipts" id="${xmlEscape(messageId)}" from="${xmlEscape(_boundJid ?? '')}"/>'
      '<no-permanent-store xmlns="urn:xmpp:hints"/>'
      '</message>',
    );
  }

  /// XEP-0333 read marker broadcast to the room (web sendDisplayedMarker):
  /// a single watermark, [messageId] is the newest displayed archive id.
  void sendDisplayedMarker({
    required String roomJid,
    required String messageId,
  }) {
    final id = 'message-displayed:${DateTime.now().millisecondsSinceEpoch}';
    _trySend(
      '<message id="$id" type="groupchat"$_fromAttr to="${xmlEscape(roomJid)}">'
      '<displayed xmlns="urn:xmpp:chat-markers:0" id="${xmlEscape(messageId)}" from="${xmlEscape(_boundJid ?? '')}"/>'
      '<store xmlns="urn:xmpp:hints"/>'
      '</message>',
    );
  }

  /// Typing exactly like web sendTypingRequest.
  Future<void> sendTyping({
    required String roomJid,
    required bool isTyping,
  }) async {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final id = isTyping ? 'typing-$ms' : 'stop-typing-$ms';
    final tag = isTyping ? 'composing' : 'paused';
    final fullName = [user.firstName, user.lastName]
        .where((e) => (e ?? '').isNotEmpty)
        .join(' ');
    _trySend(
      '<message type="groupchat" id="$id" to="${xmlEscape(roomJid)}">'
      '<$tag xmlns="http://jabber.org/protocol/chatstates"/>'
      '<data fullName="${xmlEscape(fullName)}"/>'
      '</message>',
    );
  }

  /// Read markers from the private store like web
  /// getChatsPrivateStoreRequest: `{roomJid: ms}`.
  Future<Map<String, int>> getChatsPrivateStore() async {
    final id = 'get-chats-private-req:${DateTime.now().millisecondsSinceEpoch}';
    try {
      final iq = await _sendIq(
        id,
        '<iq id="$id" type="get"><query xmlns="jabber:iq:private">'
        '<chatjson xmlns="chatjson:store"/></query></iq>',
      );
      final value =
          childOf(childOf(iq, 'query'), 'chatjson')?.getAttribute('value');
      final parsed = parsePrivateStoreValue(value);
      _privateStoreTimestamps
        ..clear()
        ..addAll(parsed);
      return Map<String, int>.from(parsed);
    } catch (e) {
      _log(ChatLogLevel.warn, 'Private store read failed: $e');
      return Map<String, int>.from(_privateStoreTimestamps);
    }
  }

  /// Writes one room's read marker; the whole map is stored, like web
  /// setChatsPrivateStoreRequest.
  Future<void> setTimestampToPrivateStore({
    required String chatId,
    required int timestamp,
  }) async {
    if (chatId.isEmpty || timestamp <= 0) return;
    _privateStoreTimestamps[chatId] = timestamp;
    final value = jsonEncode(
      _privateStoreTimestamps.map((k, v) => MapEntry(k, '$v')),
    );
    final id = 'set-chats-private-req:${DateTime.now().millisecondsSinceEpoch}';
    try {
      await _sendIq(
        id,
        '<iq id="$id" type="set"><query xmlns="jabber:iq:private">'
        '<chatjson xmlns="chatjson:store" value="${xmlEscape(value)}"/>'
        '</query></iq>',
      );
    } catch (e) {
      _log(ChatLogLevel.warn, 'Private store write failed: $e');
    }
  }

  String _dataElement(Map<String, String> attrs) {
    final buffer = StringBuffer('<data');
    attrs.forEach((key, value) {
      buffer.write(' $key="${xmlEscape(value)}"');
    });
    buffer.write('/>');
    return buffer.toString();
  }

  void _handleTransportClosed() {
    _keepAliveTimer?.cancel();
    for (final pending in _pendingIq.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('xmpp_disconnected'));
      }
    }
    _pendingIq.clear();
    final completer = _onlineCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('xmpp_disconnected'));
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manuallyClosed) return;
    if (_reconnectTimer?.isActive == true) return;
    _setState(ChatConnectionState.error);
    _reconnectAttempts += 1;
    final delaySeconds = min(30, 1 << min(_reconnectAttempts, 5));
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), connect);
  }

  Future<void> _closeTransport() async {
    _keepAliveTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        transport.send('<close xmlns="$_nsFraming"/>');
      } catch (_) {}
      await transport.close();
    }
  }

  Future<void> disconnect() async {
    _manuallyClosed = true;
    _reconnectTimer?.cancel();
    await _closeTransport();
    _setState(ChatConnectionState.offline);
  }

  /// Domain of this session (web sessionDomain): our own JID's domain, else
  /// the configured XMPP host.
  String get ownDomain {
    final jid = _boundJid ?? '';
    final at = jid.indexOf('@');
    var domain = at >= 0 ? jid.substring(at + 1) : settings.host;
    final slash = domain.indexOf('/');
    if (slash >= 0) domain = domain.substring(0, slash);
    return domain.isEmpty ? settings.host : domain;
  }

  /// Leaves a MUC for this session only (web leaveTheRoom): unavailable
  /// presence to `room/<our local part>`.
  void sendRoomLeave(String roomJid) {
    _trySend(
      '<presence to="${xmlEscape('$roomJid/$username')}" type="unavailable"/>',
    );
  }

  /// Sets a room's picture on the XMPP side (web setRoomImage). The REST
  /// picture is what survives a reload; this keeps the MUC's own profile in
  /// step. An empty [thumbnail] clears it.
  void sendRoomImage({
    required String roomJid,
    required String thumbnail,
    String background = 'none',
  }) {
    _trySend(
      buildRoomImageStanza(
        roomJid: roomJid,
        thumbnail: thumbnail,
        background: background,
      ),
    );
  }

  /// Direct MUC invite (web inviteRoomRequest). [username] is the local part.
  void sendRoomInvite({required String roomJid, required String username}) {
    final id = 'invite-rooms:${DateTime.now().millisecondsSinceEpoch}';
    _trySend(
      '<message to="${xmlEscape(roomJid)}" id="$id">'
      '<x xmlns="http://jabber.org/protocol/muc#user">'
      '<invite to="${xmlEscape('$username@${settings.host}')}"/>'
      '</x></message>',
    );
  }
}

/// The `ns:getrooms:setprofile` IQ of a room picture (web setRoomImage).
String buildRoomImageStanza({
  required String roomJid,
  required String thumbnail,
  String background = 'none',
}) {
  return '<iq id="setRoomImage" type="set">'
      '<query xmlns="ns:getrooms:setprofile" '
      'room_thumbnail="${xmlEscape(thumbnail)}" '
      'room_background="${xmlEscape(background)}" '
      'room="${xmlEscape(roomJid)}"/></iq>';
}

/// Parses the private store `chatjson` value (`{"room@conf": "1712..."}`).
Map<String, int> parsePrivateStoreValue(String? value) {
  if (value == null || value.isEmpty) return <String, int>{};
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return <String, int>{};
    final out = <String, int>{};
    decoded.forEach((key, raw) {
      final ts = timestampFromUnknown(raw?.toString());
      if (ts > 0) out['$key'] = ts;
    });
    return out;
  } catch (_) {
    return <String, int>{};
  }
}
