import 'dart:async';
import 'dart:convert';

import 'package:xml/xml.dart';

import '../networking/stanza_parser.dart' show xmlEscape;
import '../networking/xmpp_client.dart';
import 'push_storage.dart';

/// Sends an IQ and resolves with its result; an IQ error or a timeout
/// completes with an error (matches [XmppClient.sendIq]).
typedef MucSubIqSender = Future<XmlElement> Function(
  String id,
  String stanza, {
  Duration timeout,
});

/// MucSub subscribe IQ (XEP-0369) so the push server gets the room's
/// messages: `subscribe` on the `urn:xmpp:mucsub:nodes:messages` node.
String buildMucSubscribeStanza({
  required String id,
  required String roomJid,
  required String nick,
}) {
  return '<iq to="${xmlEscape(roomJid)}" type="set" id="${xmlEscape(id)}">'
      '<subscribe xmlns="urn:xmpp:mucsub:0" nick="${xmlEscape(nick)}">'
      '<event node="urn:xmpp:mucsub:nodes:messages"/>'
      '</subscribe></iq>';
}

/// Subscribes the account to MucSub messages of its rooms and remembers
/// which rooms are done (RN `PushSubscriptionService`).
class PushSubscriptionService {
  PushSubscriptionService({
    PushStorage? storage,
    this.timeout = const Duration(seconds: 5),
    this.concurrency = 8,
    this.retryCooldown = const Duration(seconds: 60),
    DateTime Function()? now,
  })  : _storage = storage ?? const SharedPreferencesPushStorage(),
        _now = now ?? DateTime.now;

  /// A room whose subscribe failed is not retried sooner than this (web
  /// `retryCooldownMs`).
  final Duration retryCooldown;
  final DateTime Function() _now;
  final Map<String, DateTime> _failedAt = <String, DateTime>{};
  final Set<String> _inFlight = <String>{};

  final PushStorage _storage;

  /// Per-subscribe IQ timeout.
  final Duration timeout;

  /// Rooms subscribed at once.
  final int concurrency;

  final Set<String> _subscribed = <String>{};
  bool _loaded = false;
  int _seq = 0;

  Future<void> _load() async {
    if (_loaded) return;
    try {
      final raw = await _storage.read(kSubscribedRoomsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _subscribed.addAll(decoded.whereType<String>());
        }
      }
    } catch (_) {
      // A corrupt list only costs a re-subscribe.
    }
    _loaded = true;
  }

  Future<void> _save() async {
    try {
      await _storage.write(
        kSubscribedRoomsKey,
        jsonEncode(_subscribed.toList()),
      );
    } catch (_) {
      // Best effort.
    }
  }

  bool isRoomSubscribed(String roomJid) => _subscribed.contains(roomJid);

  List<String> get subscribedRooms => _subscribed.toList();

  String _nextId() {
    _seq += 1;
    return 'newSubscription:'
        '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
        '${_seq.toRadixString(36)}';
  }

  /// Subscribes one room. Resolves false on an IQ error, a timeout or a
  /// closed socket; never throws.
  Future<bool> subscribeToRoom(
    MucSubIqSender send,
    String roomJid, {
    required String nick,
  }) async {
    await _load();
    final jid = roomJid.split('/').first;
    if (!jid.contains('@')) return false;
    if (_subscribed.contains(jid)) return true;
    final failedAt = _failedAt[jid];
    if (failedAt != null && _now().difference(failedAt) < retryCooldown) {
      return false;
    }
    if (!_inFlight.add(jid)) return false;
    final id = _nextId();
    try {
      await send(
        id,
        buildMucSubscribeStanza(id: id, roomJid: jid, nick: nick),
        timeout: timeout,
      );
      _subscribed.add(jid);
      _failedAt.remove(jid);
      await _save();
      return true;
    } catch (_) {
      _failedAt[jid] = _now();
      return false;
    } finally {
      _inFlight.remove(jid);
    }
  }

  /// Subscribes every room not done yet, [concurrency] at a time. Returns
  /// the number of rooms newly subscribed.
  Future<int> subscribeToRooms(
    MucSubIqSender send,
    Iterable<String> roomJids, {
    required String nick,
  }) async {
    await _load();
    final pending = roomJids
        .map((jid) => jid.split('/').first)
        .where((jid) => jid.contains('@') && !_subscribed.contains(jid))
        .toSet()
        .toList();
    var ok = 0;
    for (var i = 0; i < pending.length; i += concurrency) {
      final batch = pending.skip(i).take(concurrency);
      final results = await Future.wait(
        batch.map((jid) => subscribeToRoom(send, jid, nick: nick)),
      );
      ok += results.where((done) => done).length;
    }
    return ok;
  }

  /// Convenience for a live client.
  Future<int> subscribeClientToRooms(
    XmppClient xmpp,
    Iterable<String> roomJids,
  ) {
    return subscribeToRooms(
      (id, stanza, {Duration timeout = const Duration(seconds: 5)}) =>
          xmpp.sendIq(id, stanza, timeout: timeout),
      roomJids,
      nick: _localPart(xmpp.username),
    );
  }

  /// Clears the remembered rooms (logout).
  Future<void> reset() async {
    _subscribed.clear();
    _failedAt.clear();
    _loaded = true;
    try {
      await _storage.remove(kSubscribedRoomsKey);
    } catch (_) {
      // Best effort.
    }
  }

  static String _localPart(String jid) {
    final at = jid.indexOf('@');
    return at < 0 ? jid : jid.substring(0, at);
  }
}
