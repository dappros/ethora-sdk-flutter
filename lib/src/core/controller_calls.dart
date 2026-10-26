part of 'chat_component_controller.dart';

/// 1:1 and group audio/video calls of [ChatComponentController] (web
/// `videoCalls`). The state machine, signalling and media live in
/// [CallsCoordinator]; this part only gives it the session it needs and
/// hooks it into the XMPP client and the logout path.
extension ChatControllerCalls on ChatComponentController {
  /// The calls module. Safe to read when `config.videoCalls` is off: it then
  /// stays idle and only swallows call stanzas. The overlay widgets
  /// ([CallOverlayHost], [CallHeaderButtons]) are driven by it.
  CallsCoordinator get calls => _calls;

  /// Intercepts call stanzas on the freshly created XMPP client.
  void _wireCalls(XmppClient xmpp) {
    _calls.attach(xmpp);
    // A call push (tapped notification) rings, or joins, the call. A host
    // that set its own hook keeps it.
    onCallPush ??= (data) => _calls.handleCallPush(data);
    unawaited(_calls.startNativeCallUi());
  }

  /// Logout, session loss and dispose: drop any call and held signalling.
  void _disposeCallsRuntime() {
    _calls.reset();
    if (_disposed) _calls.dispose();
  }
}

/// What [CallsCoordinator] reads from the running chat session.
class _ControllerCallsHost implements CallsHost {
  _ControllerCallsHost(this._controller);

  final ChatComponentController _controller;

  @override
  VideoCallsConfig? get videoCalls => _controller.config.videoCalls;

  @override
  String get selfXmppUsername => _controller._myWireLocal;

  @override
  String get xmppDomain =>
      _controller._xmpp?.ownDomain ??
      _controller.config.xmppSettings?.host ??
      '';

  @override
  List<ChatRoom> get rooms => _controller.state.value.rooms;

  @override
  String get conferenceDomain =>
      _controller.config.xmppSettings?.conference ?? '';

  @override
  void addCallLog(ChatMessage message) =>
      _controller._handleIncomingMessage(message);

  @override
  bool sendStanza(String stanza) =>
      _controller._xmpp?.sendStanza(stanza) ?? false;

  @override
  void log(String message, [Object? detail]) {
    _controller._log(
      ChatLogLevel.info,
      ChatLogCategory.system,
      detail == null ? message : '$message: $detail',
    );
  }
}
