import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/push/chat_push_coordinator.dart';
import 'package:ethora_sdk_flutter/src/push/push_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'fakes.dart';
import 'support_auth.dart';

class _RecordingXmpp extends FakeXmppClient {
  _RecordingXmpp({
    required super.settings,
    required super.user,
    required super.log,
  });

  final List<String> subscribed = <String>[];

  @override
  Future<XmlElement> sendIq(
    String id,
    String stanza, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final iq = XmlDocument.parse(stanza).rootElement;
    subscribed.add(iq.getAttribute('to')!);
    return XmlElement(XmlName('iq'));
  }
}

const XmppSettings _settings = XmppSettings(
  host: 'xmpp.test',
  conference: 'conf.test',
);

void main() {
  late ValueNotifier<ChatComponentState> state;
  late _RecordingXmpp xmpp;
  late MemoryPushStorage storage;

  setUp(() {
    xmpp = _RecordingXmpp(
      settings: _settings,
      user: const ChatUser(xmppUsername: 'alice', xmppPassword: 'pw'),
      log: (_) {},
    );
    storage = MemoryPushStorage();
    state = ValueNotifier<ChatComponentState>(
      ChatComponentState(
        rooms: const <ChatRoom>[
          ChatRoom(jid: 'a@conf.test'),
          ChatRoom(jid: 'b@conf.test'),
        ],
      ),
    );
  });

  ChatPushCoordinator build(ChatComponentConfig config) {
    return ChatPushCoordinator(
      config: config,
      apiClient: buildApiClient(
        store: FakeTokenStore(),
        handler: (_) async => json(200, <String, Object?>{}),
      ),
      state: state,
      xmpp: () => xmpp,
      selectRoom: (_) async {},
      storage: storage,
    );
  }

  test('rooms are subscribed without any pushNotifications config', () async {
    final coordinator =
        build(const ChatComponentConfig(xmppSettings: _settings));
    await coordinator.onRuntimeReady();
    expect(xmpp.subscribed,
        unorderedEquals(<String>['a@conf.test', 'b@conf.test']));

    // A room that turns up later is subscribed too, and only that one.
    state.value = ChatComponentState(
      rooms: const <ChatRoom>[
        ChatRoom(jid: 'a@conf.test'),
        ChatRoom(jid: 'b@conf.test'),
        ChatRoom(jid: 'c@conf.test'),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(xmpp.subscribed.where((jid) => jid == 'c@conf.test'), hasLength(1));
    expect(xmpp.subscribed, hasLength(3));
    coordinator.dispose();
  });

  test('pushNotifications.enabled false is an explicit off', () async {
    final coordinator = build(
      const ChatComponentConfig(
        xmppSettings: _settings,
        pushNotifications: PushNotificationsConfig(enabled: false),
      ),
    );
    await coordinator.onRuntimeReady();
    expect(xmpp.subscribed, isEmpty);
    coordinator.dispose();
  });

  test('the user switch off stops MucSub too', () async {
    final coordinator =
        build(const ChatComponentConfig(xmppSettings: _settings));
    await coordinator.manager.setUserEnabled(false);
    await coordinator.onRuntimeReady();
    expect(xmpp.subscribed, isEmpty);
    coordinator.dispose();
  });

  test('the settings switch needs push to be in use', () async {
    final plain = build(const ChatComponentConfig(xmppSettings: _settings));
    expect(plain.isConfigured, isFalse);
    final configured = build(
      const ChatComponentConfig(
        xmppSettings: _settings,
        pushNotifications: PushNotificationsConfig(),
      ),
    );
    expect(configured.isConfigured, isTrue);
  });
}
