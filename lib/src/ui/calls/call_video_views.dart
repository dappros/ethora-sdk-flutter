// Video surfaces for the call screens: a flutter_webrtc renderer for p2p
// streams, and LiveKit participant tiles.

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../calls/call_display.dart';
import '../../calls/p2p/p2p_ports.dart';
import '../../theme/chat_theme.dart';

/// Renders a [P2PStream] (local preview or remote video).
class RtcStreamView extends StatefulWidget {
  const RtcStreamView({
    super.key,
    required this.stream,
    this.mirror = false,
    this.cover = true,
    this.revision = 0,
  });

  final P2PStream? stream;
  final bool mirror;
  final bool cover;

  /// Changes when the tracks of the same stream changed (camera toggled), so
  /// the renderer re-binds to the stream.
  final int revision;

  @override
  State<RtcStreamView> createState() => _RtcStreamViewState();
}

class _RtcStreamViewState extends State<RtcStreamView> {
  final rtc.RTCVideoRenderer _renderer = rtc.RTCVideoRenderer();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      if (!mounted) return;
      _bind();
      setState(() => _ready = true);
    });
  }

  void _bind() {
    final native = widget.stream?.native;
    _renderer.srcObject = native is rtc.MediaStream ? native : null;
  }

  @override
  void didUpdateWidget(RtcStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (oldWidget.stream != widget.stream ||
        oldWidget.revision != widget.revision) {
      // Re-bind so the renderer picks up an added or removed video track.
      _renderer.srcObject = null;
      _bind();
    }
  }

  @override
  void dispose() {
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    return rtc.RTCVideoView(
      _renderer,
      mirror: widget.mirror,
      objectFit: widget.cover
          ? rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
          : rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );
  }
}

/// Round avatar with the first letter of [name] (or a person glyph).
class CallAvatar extends StatelessWidget {
  const CallAvatar({super.key, required this.name, this.size = 120});

  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    final text = sanitizeCallName(name);
    final initial = text.isEmpty ? '' : String.fromCharCode(text.runes.first);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.primary,
      ),
      alignment: Alignment.center,
      child: initial.isEmpty
          ? Icon(Icons.person, size: size * 0.55, color: Colors.white)
          : Text(
              initial.toUpperCase(),
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w500,
              ),
            ),
    );
  }
}

/// One LiveKit participant: their camera when it is publishing, else an
/// avatar with their name.
class LiveKitParticipantTile extends StatelessWidget {
  const LiveKitParticipantTile({
    super.key,
    required this.participant,
    this.mirror = false,
    this.showName = false,
    this.avatarSize = 96,
    this.highlightSpeaking = false,
  });

  final lk.Participant participant;
  final bool mirror;
  final bool showName;
  final double avatarSize;

  /// Outline the tile while this participant speaks (group calls).
  final bool highlightSpeaking;

  String get _displayName {
    final named = sanitizeCallName(participant.name);
    return named.isNotEmpty ? named : sanitizeCallName(participant.identity);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: participant,
      builder: (context, _) {
        lk.VideoTrack? track;
        for (final pub in participant.videoTrackPublications) {
          if (pub.source == lk.TrackSource.camera &&
              !pub.muted &&
              pub.track != null) {
            track = pub.track as lk.VideoTrack?;
            break;
          }
        }
        final name = _displayName;
        final speaking = highlightSpeaking && participant.isSpeaking;
        final tile = Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(
              color: const Color(0xFF111A2E),
              child: Center(child: CallAvatar(name: name, size: avatarSize)),
            ),
            if (track != null)
              lk.VideoTrackRenderer(
                track,
                fit: lk.VideoViewFit.cover,
                mirrorMode: mirror
                    ? lk.VideoViewMirrorMode.mirror
                    : lk.VideoViewMirrorMode.off,
              ),
            if (showName && name.isNotEmpty)
              Positioned(
                left: 8,
                bottom: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        );
        if (!highlightSpeaking) return tile;
        final primary = ChatUiScope.of(context).theme.primary;
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(
              color: speaking ? primary : Colors.transparent,
              width: 3,
            ),
          ),
          child: tile,
        );
      },
    );
  }
}
