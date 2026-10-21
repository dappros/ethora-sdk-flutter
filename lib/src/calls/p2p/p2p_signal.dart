// Wire format of the peer to peer call signalling (web calls/p2p/signalStanza
// .ts). It travels as a direct XMPP chat message between the two users, no
// server involvement:
//
//   <message type="chat" to="<peer bare jid>">
//     <body>system</body>
//     <data type="call-p2p" callId="..." signal="offer|answer|candidate|end"
//           payload="<JSON string>"/>
//   </message>
//
// payload is the SDP init ({type, sdp}) for offer/answer, the ICE candidate
// init for candidate and {reason} for end. This module only builds and parses
// stanzas, so it stays unit testable without a connection.

import 'dart:convert';

import 'package:xml/xml.dart';

import '../../networking/stanza_parser.dart' show childOf, xmlEscape;
import '../call_stanza.dart' show extractNumericTimestamp;

const String kP2pSignalType = 'call-p2p';

enum P2PSignalName { offer, answer, candidate, end }

/// One ICE candidate init (`RTCIceCandidateInit`).
class P2PCandidate {
  const P2PCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.usernameFragment,
  });

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final String? usernameFragment;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
        'usernameFragment': usernameFragment,
      };

  /// Identity used to apply a re-sent candidate only once.
  String get key => '$candidate|${sdpMid ?? ''}|${sdpMLineIndex ?? ''}';
}

/// A signal payload: an SDP for offer/answer, a candidate, or an end reason.
class P2PSignalPayload {
  const P2PSignalPayload.sdp(String this.sdp)
      : candidate = null,
        reason = null;
  const P2PSignalPayload.candidate(P2PCandidate this.candidate)
      : sdp = null,
        reason = null;
  const P2PSignalPayload.end([this.reason])
      : sdp = null,
        candidate = null;

  final String? sdp;
  final P2PCandidate? candidate;
  final String? reason;
}

class P2PSignal {
  const P2PSignal({
    required this.callId,
    required this.signal,
    required this.payload,
    required this.fromBare,
    required this.fromLocal,
    this.ageMs,
    this.delayed = false,
  });

  final String callId;
  final P2PSignalName signal;
  final P2PSignalPayload payload;

  /// Sender's bare JID as written in `from` (lower-cased), '' when missing.
  final String fromBare;

  /// Sender's xmpp localpart (the part before '@'), '' when missing.
  final String fromLocal;

  /// Age from the server's stanza-id timestamp, null when the stanza carries
  /// none (direct messages often do not).
  final int? ageMs;

  /// Carries `<delay/>`: it was stored offline and replayed, so it is stale.
  final bool delayed;
}

// SDP for a call with audio + video sections is a few KB; this only guards
// against a hostile peer pushing megabytes through an attribute.
const int _maxSdpLength = 64 * 1024;
const int _maxReasonLength = 64;

/// A signal older than this (by the server's own timestamp) is not part of a
/// live negotiation. Call-tokens use 5 s; signalling gets more headroom
/// because candidates can queue behind a slow permission prompt on the
/// sender, but anything the server replays after a reconnect is far older.
const int kMaxP2pSignalAgeMs = 15000;

int _outgoingCounter = 0;

/// Builds the signal stanza as XML text.
String buildP2PSignalStanza({
  required String to,
  required String callId,
  required P2PSignalName signal,
  P2PSignalPayload? payload,
  int? nowMs,
}) {
  _outgoingCounter = (_outgoingCounter + 1) % 1000000;
  final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final body = <String, dynamic>{};
  final p = payload;
  if (p != null) {
    switch (signal) {
      case P2PSignalName.offer:
      case P2PSignalName.answer:
        body['type'] = signal.name;
        body['sdp'] = p.sdp ?? '';
      case P2PSignalName.candidate:
        body.addAll(p.candidate?.toJson() ?? const <String, dynamic>{});
      case P2PSignalName.end:
        if (p.reason != null) body['reason'] = p.reason;
    }
  }
  // jsonEncode escapes newlines in the SDP, so the attribute survives XML
  // attribute-value normalisation on the receiving parser.
  return '<message to="${xmlEscape(to)}" type="chat" '
      'id="call-p2p-$ms-$_outgoingCounter">'
      '<body>system</body>'
      '<data type="$kP2pSignalType" callId="${xmlEscape(callId)}" '
      'signal="${signal.name}" '
      'payload="${xmlEscape(jsonEncode(body))}"/>'
      // Signalling is only meaningful live: keep it out of the archive and
      // the offline store (a replayed offer for a finished call is noise).
      '<no-store xmlns="urn:xmpp:hints"/>'
      '<no-permanent-store xmlns="urn:xmpp:hints"/>'
      '</message>';
}

P2PSignalName? _signalByName(String name) {
  for (final value in P2PSignalName.values) {
    if (value.name == name) return value;
  }
  return null;
}

P2PSignalPayload? _validatePayload(P2PSignalName signal, Object? raw) {
  if (raw is! Map) return null;
  if (signal == P2PSignalName.offer || signal == P2PSignalName.answer) {
    if (raw['type'] != signal.name) return null;
    final sdp = raw['sdp'];
    if (sdp is! String || sdp.isEmpty || sdp.length > _maxSdpLength) {
      return null;
    }
    return P2PSignalPayload.sdp(sdp);
  }
  if (signal == P2PSignalName.candidate) {
    final candidate = raw['candidate'];
    if (candidate is! String || candidate.length > 2048) return null;
    final mid = raw['sdpMid'];
    final index = raw['sdpMLineIndex'];
    final ufrag = raw['usernameFragment'];
    return P2PSignalPayload.candidate(
      P2PCandidate(
        candidate: candidate,
        sdpMid: mid is String ? mid : null,
        sdpMLineIndex: index is num ? index.toInt() : null,
        usernameFragment: ufrag is String ? ufrag : null,
      ),
    );
  }
  final reason = raw['reason'];
  return P2PSignalPayload.end(
    reason is String
        ? (reason.length > _maxReasonLength
            ? reason.substring(0, _maxReasonLength)
            : reason)
        : null,
  );
}

// The server stamps a microsecond id on archived stanzas and the first 13
// digits are epoch ms (same trick as the call-token freshness check).
int? _stanzaAgeMs(XmlElement stanza, int now) {
  final id = (childOf(stanza, 'stanza-id')?.getAttribute('id') ?? '').trim();
  if (id.isEmpty) return null;
  final match = RegExp(r'\d{13,}').firstMatch(id)?.group(0);
  if (match == null) return null;
  final ts = extractNumericTimestamp(match);
  return ts == null || ts <= 0 ? null : (now - ts).abs();
}

/// Reads a `call-p2p` message. Returns null for anything that is not a well
/// formed signal (wrong type, unknown signal, bad JSON, bad payload).
P2PSignal? parseP2PSignalStanza(XmlElement stanza, {int? nowMs}) {
  final data = childOf(stanza, 'data');
  if (data == null ||
      (data.getAttribute('type') ?? '').toLowerCase() != kP2pSignalType) {
    return null;
  }
  final callId =
      (data.getAttribute('callId') ?? data.getAttribute('callid') ?? '').trim();
  final signalName = (data.getAttribute('signal') ?? '').trim().toLowerCase();
  final signal = _signalByName(signalName);
  if (callId.isEmpty || signal == null) return null;

  Object? parsed;
  try {
    parsed = jsonDecode(data.getAttribute('payload') ?? '{}');
  } catch (_) {
    return null;
  }
  final payload = _validatePayload(signal, parsed);
  if (payload == null) return null;

  final fromBare =
      (stanza.getAttribute('from') ?? '').split('/').first.trim().toLowerCase();
  return P2PSignal(
    callId: callId,
    signal: signal,
    payload: payload,
    fromBare: fromBare,
    fromLocal: fromBare.split('@').first,
    ageMs: _stanzaAgeMs(stanza, nowMs ?? DateTime.now().millisecondsSinceEpoch),
    delayed: childOf(stanza, 'delay') != null,
  );
}

/// Whether a parsed signal belongs to a live negotiation. An `end` is always
/// accepted unless replayed (it only ever acts on a call that is still
/// active, and stopping a call late is better than never).
bool isP2PSignalFresh(P2PSignal signal) {
  if (signal.delayed) return false;
  if (signal.signal == P2PSignalName.end) return true;
  final age = signal.ageMs;
  return age == null || age <= kMaxP2pSignalAgeMs;
}
