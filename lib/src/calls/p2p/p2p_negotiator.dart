// The pure half of the p2p signalling state machine (web calls/p2p/
// negotiator.ts): given the stream of signals from the peer and a few "we are
// ready" notifications, it says WHAT to do next (apply an offer, apply an
// answer, add a candidate, stop) without touching a peer connection. The
// controller executes the commands.
//
// Rules it enforces:
//  - one negotiation per callId; signals for another callId or from anyone but
//    the expected peer are ignored;
//  - the callee may receive the offer before it has accepted (and before it
//    has local media): the first offer wins, later initial offers are ignored,
//    and it is held until markReady();
//  - candidates that arrive before the remote description is applied are held
//    and flushed right after it;
//  - duplicates (same SDP delivered twice, e.g. the caller re-sending its
//    offer) are no-ops;
//  - after the first exchange, a new offer is a renegotiation (ICE restart).
//    If both sides restart at once (glare) the caller is "impolite" and keeps
//    its own offer; the callee is "polite" and yields to the caller's.

import 'p2p_signal.dart';

enum P2PRole { caller, callee }

sealed class NegotiatorCommand {
  const NegotiatorCommand();
}

class ApplyOffer extends NegotiatorCommand {
  const ApplyOffer({
    required this.sdp,
    required this.initial,
    required this.rollback,
  });
  final String sdp;
  final bool initial;
  final bool rollback;
}

class ApplyAnswer extends NegotiatorCommand {
  const ApplyAnswer(this.sdp);
  final String sdp;
}

class AddCandidate extends NegotiatorCommand {
  const AddCandidate(this.candidate);
  final P2PCandidate candidate;
}

class RemoteEnd extends NegotiatorCommand {
  const RemoteEnd(this.reason);
  final String reason;
}

const int _maxHeldCandidates = 64;

class P2PNegotiator {
  P2PNegotiator({
    required this.callId,
    required this.role,
    required String peerLocal,
  }) : _peerLocal = peerLocal.split('@').first.toLowerCase();

  final String callId;
  final P2PRole role;
  final String _peerLocal;

  bool _ready = false;
  bool _ended = false;
  bool _remoteDescriptionSet = false;
  bool _initialOfferTaken = false;
  String? _heldOffer;
  bool _localOfferPending = false;
  String? _lastOfferSdp;
  String? _lastAnswerSdp;
  List<P2PCandidate> _heldCandidates = <P2PCandidate>[];
  // The caller re-sends its offer and candidates while unanswered, so the same
  // candidate can arrive more than once; each is applied (or held) only once.
  final Set<String> _seenCandidates = <String>{};

  bool get isEnded => _ended;

  /// True while we have sent an offer and not yet received its answer.
  bool get awaitingAnswer => _localOfferPending;

  bool _accepts(P2PSignal signal) {
    if (_ended) return false;
    if (signal.callId != callId) return false;
    if (_peerLocal.isNotEmpty && signal.fromLocal != _peerLocal) return false;
    return true;
  }

  List<NegotiatorCommand> receive(P2PSignal signal) {
    if (!_accepts(signal)) return const <NegotiatorCommand>[];

    switch (signal.signal) {
      case P2PSignalName.end:
        _ended = true;
        _heldOffer = null;
        _heldCandidates = <P2PCandidate>[];
        final reason = signal.payload.reason;
        return <NegotiatorCommand>[
          RemoteEnd(reason == null || reason.isEmpty ? 'ended' : reason),
        ];

      case P2PSignalName.offer:
        final sdp = signal.payload.sdp ?? '';
        if (sdp == _lastOfferSdp) return const <NegotiatorCommand>[];
        if (!_initialOfferTaken) {
          // Only the callee ever receives the first offer.
          if (role != P2PRole.callee) return const <NegotiatorCommand>[];
          _initialOfferTaken = true;
          _lastOfferSdp = sdp;
          if (!_ready) {
            _heldOffer = sdp;
            return const <NegotiatorCommand>[];
          }
          return <NegotiatorCommand>[
            ApplyOffer(sdp: sdp, initial: true, rollback: false),
          ];
        }
        // Renegotiation. Before the initial exchange finished, or before we
        // are ready, there is nothing sensible to apply it to.
        if (!_ready || !_remoteDescriptionSet) {
          return const <NegotiatorCommand>[];
        }
        if (_localOfferPending) {
          if (role == P2PRole.caller) {
            return const <NegotiatorCommand>[]; // impolite: keep ours
          }
          _localOfferPending = false; // polite: roll ours back
          _lastOfferSdp = sdp;
          return <NegotiatorCommand>[
            ApplyOffer(sdp: sdp, initial: false, rollback: true),
          ];
        }
        _lastOfferSdp = sdp;
        return <NegotiatorCommand>[
          ApplyOffer(sdp: sdp, initial: false, rollback: false),
        ];

      case P2PSignalName.answer:
        if (!_localOfferPending) return const <NegotiatorCommand>[];
        final sdp = signal.payload.sdp ?? '';
        if (sdp == _lastAnswerSdp) return const <NegotiatorCommand>[];
        _lastAnswerSdp = sdp;
        _localOfferPending = false;
        return <NegotiatorCommand>[ApplyAnswer(sdp)];

      case P2PSignalName.candidate:
        final c = signal.payload.candidate;
        // An empty candidate string is the end-of-candidates marker; nothing
        // needs to be added for it.
        if (c == null || c.candidate.isEmpty) {
          return const <NegotiatorCommand>[];
        }
        if (!_seenCandidates.add(c.key)) return const <NegotiatorCommand>[];
        if (_remoteDescriptionSet) return <NegotiatorCommand>[AddCandidate(c)];
        if (_heldCandidates.length < _maxHeldCandidates) {
          _heldCandidates.add(c);
        }
        return const <NegotiatorCommand>[];
    }
  }

  /// Local media and the peer connection exist. For the callee this releases
  /// the offer that arrived while it was still on the ring screen.
  List<NegotiatorCommand> markReady() {
    if (_ended) return const <NegotiatorCommand>[];
    _ready = true;
    final held = _heldOffer;
    if (held != null) {
      _heldOffer = null;
      return <NegotiatorCommand>[
        ApplyOffer(sdp: held, initial: true, rollback: false),
      ];
    }
    return const <NegotiatorCommand>[];
  }

  /// We created and set a local offer; its answer is now expected.
  void markLocalOffer() {
    _localOfferPending = true;
    _lastAnswerSdp = null;
    // The caller's own first offer IS its initial exchange, so any offer it
    // receives afterwards is a renegotiation, not a second "first offer".
    if (role == P2PRole.caller) _initialOfferTaken = true;
  }

  /// A remote description (offer or answer) was applied to the connection.
  /// Returns the candidates that were waiting for it.
  List<NegotiatorCommand> markRemoteApplied() {
    _remoteDescriptionSet = true;
    final held = _heldCandidates;
    _heldCandidates = <P2PCandidate>[];
    return held.map<NegotiatorCommand>(AddCandidate.new).toList();
  }

  /// Local teardown: later signals are ignored.
  void stop() {
    _ended = true;
    _heldOffer = null;
    _heldCandidates = <P2PCandidate>[];
  }
}
