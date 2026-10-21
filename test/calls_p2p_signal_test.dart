import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_ice_policy.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_negotiator.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_signal.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_signal_inbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

P2PSignal signal(
  P2PSignalName name, {
  String callId = 'c1',
  String from = 'peer',
  P2PSignalPayload? payload,
}) {
  return P2PSignal(
    callId: callId,
    signal: name,
    payload: payload ?? const P2PSignalPayload.end(),
    fromBare: '$from@host',
    fromLocal: from,
  );
}

P2PSignal offer(String sdp, {String from = 'peer', String callId = 'c1'}) =>
    signal(
      P2PSignalName.offer,
      payload: P2PSignalPayload.sdp(sdp),
      from: from,
      callId: callId,
    );

P2PSignal answer(String sdp) =>
    signal(P2PSignalName.answer, payload: P2PSignalPayload.sdp(sdp));

P2PSignal candidate(String text, {int index = 0}) => signal(
      P2PSignalName.candidate,
      payload: P2PSignalPayload.candidate(
        P2PCandidate(candidate: text, sdpMid: '0', sdpMLineIndex: index),
      ),
    );

P2PSignal end([String? reason]) =>
    signal(P2PSignalName.end, payload: P2PSignalPayload.end(reason));

List<String> names(List<NegotiatorCommand> commands) => commands
    .map((c) => switch (c) {
          ApplyOffer(:final initial, :final rollback) =>
            'offer${initial ? ':initial' : ''}${rollback ? ':rollback' : ''}',
          ApplyAnswer() => 'answer',
          AddCandidate(:final candidate) => 'cand:${candidate.candidate}',
          RemoteEnd(:final reason) => 'end:$reason',
        })
    .toList();

void main() {
  group('signal stanza', () {
    test('every signal round trips through build and parse', () {
      const sdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nm=audio 9 UDP';
      final stanzas = <(P2PSignalName, P2PSignalPayload)>[
        (P2PSignalName.offer, const P2PSignalPayload.sdp(sdp)),
        (P2PSignalName.answer, const P2PSignalPayload.sdp(sdp)),
        (
          P2PSignalName.candidate,
          const P2PSignalPayload.candidate(
            P2PCandidate(
              candidate: 'candidate:1 1 udp 2 10.0.0.1 5000 typ host',
              sdpMid: '0',
              sdpMLineIndex: 0,
              usernameFragment: 'abcd',
            ),
          ),
        ),
        (P2PSignalName.end, const P2PSignalPayload.end('hangup')),
      ];
      for (final (name, payload) in stanzas) {
        final xml = buildP2PSignalStanza(
          to: 'peer@host',
          callId: 'call"1',
          signal: name,
          payload: payload,
          nowMs: 5,
        );
        final root = XmlDocument.parse(xml).rootElement
          ..setAttribute('from', 'Me@Host/res');
        expect(root.getAttribute('to'), 'peer@host');
        expect(root.getAttribute('type'), 'chat');
        expect(root.getElement('body')!.innerText, 'system');
        expect(
          root.childElements.map((e) => e.name.local),
          containsAll(<String>['no-store', 'no-permanent-store']),
        );
        final parsed = parseP2PSignalStanza(root, nowMs: 5)!;
        expect(parsed.callId, 'call"1');
        expect(parsed.signal, name);
        expect(parsed.fromBare, 'me@host');
        expect(parsed.fromLocal, 'me');
        expect(parsed.payload.sdp, payload.sdp);
        expect(
            parsed.payload.candidate?.candidate, payload.candidate?.candidate);
        expect(parsed.payload.candidate?.sdpMid, payload.candidate?.sdpMid);
        expect(parsed.payload.reason, payload.reason);
        expect(parsed.ageMs, isNull);
        expect(parsed.delayed, isFalse);
      }
    });

    test('malformed signals parse to null, never throw', () {
      XmlElement msg(String data) => XmlDocument.parse(
            '<message from="p@h" type="chat"><data $data/></message>',
          ).rootElement;
      expect(parseP2PSignalStanza(msg('type="call-state" callId="c"')), isNull);
      expect(
          parseP2PSignalStanza(msg('type="call-p2p" signal="offer"')), isNull,
          reason: 'no callId');
      expect(
        parseP2PSignalStanza(msg('type="call-p2p" callId="c" signal="nope"')),
        isNull,
      );
      expect(
        parseP2PSignalStanza(
            msg('type="call-p2p" callId="c" signal="offer" payload="{bad"')),
        isNull,
      );
      expect(
        parseP2PSignalStanza(msg(
            'type="call-p2p" callId="c" signal="offer" payload="{&quot;type&quot;:&quot;answer&quot;,&quot;sdp&quot;:&quot;x&quot;}"')),
        isNull,
        reason: 'offer payload must say offer',
      );
      expect(
        parseP2PSignalStanza(
            msg('type="call-p2p" callId="c" signal="candidate" payload="{}"')),
        isNull,
      );
      expect(parseP2PSignalStanza(XmlDocument.parse('<message/>').rootElement),
          isNull);
    });

    test('age comes from the stanza-id, replays carry a delay', () {
      final base = buildP2PSignalStanza(
        to: 'a@h',
        callId: 'c',
        signal: P2PSignalName.end,
      ).replaceFirst(
          '</message>',
          '<stanza-id xmlns="urn:xmpp:sid:0" by="x" id="1760000000000999"/>'
              '<delay xmlns="urn:xmpp:delay" stamp="2026-01-01T00:00:00Z"/></message>');
      final root = XmlDocument.parse(base).rootElement;
      final parsed = parseP2PSignalStanza(root, nowMs: 1760000010000)!;
      expect(parsed.ageMs, 10000);
      expect(parsed.delayed, isTrue);
      expect(isP2PSignalFresh(parsed), isFalse, reason: 'replayed');
    });

    test('freshness: 15 s for negotiation signals, an end is always fresh', () {
      P2PSignal aged(P2PSignalName name, int? age) => P2PSignal(
            callId: 'c',
            signal: name,
            payload: const P2PSignalPayload.end(),
            fromBare: 'p@h',
            fromLocal: 'p',
            ageMs: age,
          );
      expect(isP2PSignalFresh(aged(P2PSignalName.offer, null)), isTrue);
      expect(isP2PSignalFresh(aged(P2PSignalName.offer, 14000)), isTrue);
      expect(isP2PSignalFresh(aged(P2PSignalName.offer, 16000)), isFalse);
      expect(isP2PSignalFresh(aged(P2PSignalName.candidate, 16000)), isFalse);
      expect(isP2PSignalFresh(aged(P2PSignalName.end, 60000)), isTrue);
    });
  });

  group('P2PSignalInbox', () {
    test('signals for an unclaimed call are held and replayed in order', () {
      final inbox = P2PSignalInbox();
      expect(inbox.receive(offer('o')), SignalDelivery.buffered);
      expect(inbox.receive(candidate('c1')), SignalDelivery.buffered);
      final seen = <String>[];
      inbox.attach('c1', (s) => seen.add(s.signal.name));
      expect(seen, <String>['offer', 'candidate']);
      expect(inbox.receive(answer('a')), SignalDelivery.delivered);
      expect(seen.last, 'answer');
    });

    test('held signals expire, are bounded, and closed calls drop stragglers',
        () {
      var now = 0;
      final inbox = P2PSignalInbox(
        ttlMs: 1000,
        maxPendingCalls: 2,
        maxPerCall: 2,
        now: () => now,
      );
      inbox.receive(offer('o', callId: 'a'));
      now = 2000;
      final seen = <String>[];
      inbox.attach('a', (s) => seen.add(s.callId));
      expect(seen, isEmpty, reason: 'expired before anyone attached');

      inbox.receive(offer('o', callId: 'x'));
      inbox.receive(offer('o', callId: 'y'));
      inbox.receive(offer('o', callId: 'z'));
      final xs = <String>[];
      inbox.attach('x', (s) => xs.add(s.callId));
      expect(xs, isEmpty, reason: 'oldest unclaimed call was dropped');

      expect(inbox.receive(candidate('1')), SignalDelivery.buffered);
      expect(inbox.receive(candidate('2')), SignalDelivery.buffered);
      expect(inbox.receive(candidate('3')), SignalDelivery.dropped);

      final detach = inbox.attach('q', (_) {});
      detach();
      expect(inbox.receive(offer('o', callId: 'q')), SignalDelivery.dropped,
          reason: 'a finished call takes no more signals');
    });
  });

  group('P2PNegotiator', () {
    P2PNegotiator callee() => P2PNegotiator(
          callId: 'c1',
          role: P2PRole.callee,
          peerLocal: 'peer@host',
        );
    P2PNegotiator caller() => P2PNegotiator(
          callId: 'c1',
          role: P2PRole.caller,
          peerLocal: 'peer',
        );

    test('callee holds the first offer until ready, then applies it once', () {
      final n = callee();
      expect(names(n.receive(offer('o1'))), isEmpty);
      expect(names(n.receive(offer('o1'))), isEmpty, reason: 'duplicate');
      expect(names(n.markReady()), <String>['offer:initial']);
      expect(names(n.markReady()), isEmpty);
      expect(names(n.receive(offer('o2'))), isEmpty,
          reason: 'remote description not applied yet');
    });

    test('a ready callee applies the first offer at once; caller ignores one',
        () {
      final n = callee()..markReady();
      expect(names(n.receive(offer('o1'))), <String>['offer:initial']);
      final c = caller()..markReady();
      expect(names(c.receive(offer('o1'))), isEmpty);
    });

    test('candidates are held until the remote description, deduped', () {
      final n = callee();
      expect(names(n.receive(candidate('a'))), isEmpty);
      expect(names(n.receive(candidate('a'))), isEmpty);
      expect(names(n.receive(candidate('b'))), isEmpty);
      n.receive(offer('o1'));
      n.markReady();
      expect(names(n.markRemoteApplied()), <String>['cand:a', 'cand:b']);
      expect(names(n.receive(candidate('c'))), <String>['cand:c']);
      expect(names(n.receive(candidate('c'))), isEmpty, reason: 'seen');
      expect(
        names(n.receive(signal(
          P2PSignalName.candidate,
          payload:
              const P2PSignalPayload.candidate(P2PCandidate(candidate: '')),
        ))),
        isEmpty,
        reason: 'end-of-candidates marker',
      );
    });

    test('the caller applies an answer only while its offer is pending', () {
      final n = caller()..markReady();
      expect(names(n.receive(answer('a1'))), isEmpty);
      n.markLocalOffer();
      expect(n.awaitingAnswer, isTrue);
      expect(names(n.receive(answer('a1'))), <String>['answer']);
      expect(n.awaitingAnswer, isFalse);
      expect(names(n.receive(answer('a1'))), isEmpty);
    });

    test(
        'glare on an ICE restart: the caller keeps its offer, the callee '
        'yields', () {
      final c = caller()..markReady();
      c
        ..markLocalOffer()
        ..receive(answer('a'))
        ..markRemoteApplied()
        ..markLocalOffer(); // restart offer in flight
      expect(names(c.receive(offer('theirs'))), isEmpty, reason: 'impolite');

      final k = callee()..markReady();
      k.receive(offer('first'));
      k.markRemoteApplied();
      k.markLocalOffer(); // its own restart offer in flight
      expect(names(k.receive(offer('callers'))), <String>['offer:rollback']);
      // And a plain renegotiation with nothing pending is applied as is.
      final p = callee()..markReady();
      p.receive(offer('first'));
      p.markRemoteApplied();
      expect(names(p.receive(offer('again'))), <String>['offer']);
    });

    test('signals for another call or another peer are ignored; end stops it',
        () {
      final n = callee()..markReady();
      expect(names(n.receive(offer('o', callId: 'other'))), isEmpty);
      expect(names(n.receive(offer('o', from: 'stranger'))), isEmpty);
      expect(names(n.receive(end('hangup'))), <String>['end:hangup']);
      expect(n.isEnded, isTrue);
      expect(names(n.receive(offer('o'))), isEmpty);
      expect(names(n.markReady()), isEmpty);
      expect(names(callee().receive(end())), <String>['end:ended']);
    });
  });

  group('IceRestartPolicy', () {
    test('disconnected waits, then restarts once; recovery resets the outage',
        () {
      final p = IceRestartPolicy();
      final wait = p.onState(P2PConnState.disconnected);
      expect(wait, isA<IceWait>());
      expect((wait as IceWait).ms, 3000);
      expect(p.onState(P2PConnState.disconnected), isA<IceWait>());
      final restart = p.onGraceElapsed();
      expect(restart, isA<IceRestart>());
      expect((restart as IceRestart).deadlineMs, 15000);
      expect(p.restartCount, 1);
      // Same outage: no second wait, no second restart.
      expect(p.onState(P2PConnState.disconnected), isA<IceNone>());
      final again = p.onState(P2PConnState.failed);
      expect(again, isA<IceGiveUp>());
      expect((again as IceGiveUp).reason, 'restart-did-not-recover');
    });

    test('failed restarts straight away, a blip that heals does not restart',
        () {
      final p = IceRestartPolicy();
      expect(p.onState(P2PConnState.failed), isA<IceRestart>());
      expect(p.onState(P2PConnState.connected), isA<IceRecovered>());
      expect(p.onState(P2PConnState.connected), isA<IceNone>());

      final q = IceRestartPolicy();
      expect(q.onState(P2PConnState.disconnected), isA<IceWait>());
      expect(q.onState(P2PConnState.connected), isA<IceRecovered>());
      expect(q.onGraceElapsed(), isA<IceNone>(),
          reason: 'healed during the grace period');
      expect(q.restartCount, 0);
    });

    test('a flapping network gives up after the per-call cap', () {
      final p = IceRestartPolicy(maxRestartsPerCall: 2);
      for (var i = 0; i < 2; i++) {
        expect(p.onState(P2PConnState.failed), isA<IceRestart>());
        p.onState(P2PConnState.connected);
      }
      final last = p.onState(P2PConnState.failed);
      expect(last, isA<IceGiveUp>());
      expect((last as IceGiveUp).reason, 'too-many-restarts');
    });

    test('the restart deadline gives up only when still down', () {
      final p = IceRestartPolicy();
      expect(p.onRestartDeadline(true), isA<IceGiveUp>());
      expect(p.onRestartDeadline(false), isA<IceNone>());
      expect(p.onState(P2PConnState.connecting), isA<IceNone>());
      expect(p.onState(P2PConnState.closed), isA<IceNone>());
      expect(p.onState(P2PConnState.newState), isA<IceNone>());
    });
  });
}
