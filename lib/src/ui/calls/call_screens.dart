// The call screens: ring (incoming / outgoing / error) and the active call
// for both transports. Always dark, like a phone call screen, with the SDK
// accent colour on the avatar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../calls/call_display.dart';
import '../../calls/call_mode.dart';
import '../../calls/call_state.dart';
import '../../calls/livekit_room_session.dart';
import '../../calls/livekit_session_port.dart';
import '../../calls/p2p/p2p_call_controller.dart';
import '../../i18n/chat_i18n.dart';
import '../../theme/chat_theme.dart';
import 'call_text.dart';
import 'call_video_views.dart';
import 'group_grid_layout.dart';

const Color _stageTop = Color(0xFF0B1730);
const Color _stageBottom = Color(0xFF050B18);
const Color _callGreen = Color(0xFF10B981);

/// A round call control (mute, camera, hang up, accept ...).
class CallControlButton extends StatelessWidget {
  const CallControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.background = const Color(0x33FFFFFF),
    this.size = 56,
    this.active = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color background;
  final double size;

  /// An inactive (off) toggle is drawn with a white fill and dark glyph.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final fill = active ? background : Colors.white;
    final glyph = active ? Colors.white : const Color(0xFF111A2E);
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: fill,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: glyph, size: size * 0.46),
            ),
          ),
        ),
      ),
    );
  }
}

class _StageBackground extends StatelessWidget {
  const _StageBackground({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_stageTop, _stageBottom],
        ),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: child,
      ),
    );
  }
}

String _title(CallSessionState state, ChatStrings strings) {
  final name = state.roomName ?? '';
  if (name.isNotEmpty) return name;
  return state.isIncoming
      ? callText(strings, 'call.incoming', kNeutralIncomingCallLabel)
      : callText(strings, 'call.callTitle', 'Call');
}

String _kindNoun(CallSessionState state, ChatStrings strings) {
  final video = state.kind == CallKind.video;
  if (state.isGroup) {
    return video
        ? callText(strings, 'call.groupVideo', 'Group video call')
        : callText(strings, 'call.groupAudio', 'Group audio call');
  }
  return video
      ? callText(strings, 'call.videoCall', 'Video call')
      : callText(strings, 'call.audioCall', 'Audio call');
}

/// Ring screen shared by the incoming, outgoing and error variants.
class CallRingScreen extends StatefulWidget {
  const CallRingScreen({
    super.key,
    required this.state,
    this.onAccept,
    this.onDecline,
    this.onCancel,
    this.onDismiss,
  });

  final CallSessionState state;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final VoidCallback? onCancel;
  final VoidCallback? onDismiss;

  @override
  State<CallRingScreen> createState() => _CallRingScreenState();
}

class _CallRingScreenState extends State<CallRingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _haptics;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _syncHaptics();
  }

  @override
  void didUpdateWidget(CallRingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncHaptics();
  }

  // An incoming call buzzes until it is answered or gone.
  void _syncHaptics() {
    final ringing = widget.state.isRingingIncoming;
    if (ringing && _haptics == null) {
      HapticFeedback.vibrate();
      _haptics = Timer.periodic(
        const Duration(seconds: 2),
        (_) => HapticFeedback.vibrate(),
      );
    } else if (!ringing) {
      _haptics?.cancel();
      _haptics = null;
    }
  }

  @override
  void dispose() {
    _haptics?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ChatUiScope.of(context);
    final strings = scope.strings;
    final theme = scope.theme;
    final state = widget.state;
    final isError = state.phase == CallPhase.error;
    final incoming = state.isRingingIncoming;

    final header = incoming
        ? (state.isGroup
            ? callText(
                strings,
                state.kind == CallKind.audio
                    ? 'call.incomingGroupAudio'
                    : 'call.incomingGroupVideo',
                state.kind == CallKind.audio
                    ? 'Incoming group audio call'
                    : 'Incoming group video call',
              )
            : callText(
                strings,
                state.kind == CallKind.audio
                    ? 'call.incomingAudio'
                    : 'call.incomingVideo',
                state.kind == CallKind.audio
                    ? 'Incoming audio call'
                    : 'Incoming video call',
              ))
        : isError
            ? callText(strings, 'call.failed', 'Call failed')
            : state.phase == CallPhase.connecting
                ? callText(strings, 'call.connecting', 'Connecting...')
                : state.peerRinging
                    ? callText(strings, 'call.ringing', 'Ringing...')
                    : callText(strings, 'call.calling', 'Calling...');

    var subtitle = _kindNoun(state, strings);
    if (incoming &&
        state.isGroup &&
        (state.callerName ?? '').isNotEmpty &&
        (state.roomName ?? '').isNotEmpty) {
      subtitle = callText(
        strings,
        'call.callerInRoom',
        '{caller} is calling in {room}',
        <String, Object>{
          'caller': state.callerName!,
          'room': state.roomName!,
        },
      );
    } else if (isError) {
      subtitle = callText(strings, 'call.tryAgain', 'Please try again later');
    }

    return _StageBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: <Widget>[
              Text(
                header,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const Spacer(),
              SizedBox(
                width: 200,
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    if (!isError)
                      for (final offset in const <double>[0, 0.5])
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, _) {
                            final t = (_pulse.value + offset) % 1;
                            return Opacity(
                              opacity: (1 - t) * 0.55,
                              child: Container(
                                width: 120 + 80 * t,
                                height: 120 + 80 * t,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: theme.primary,
                                    width: 2,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                    CallAvatar(name: state.roomName, size: 120),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _title(state, strings),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    state.kind == CallKind.audio ? Icons.call : Icons.videocam,
                    size: 18,
                    color: Colors.white60,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 14),
                    ),
                  ),
                ],
              ),
              if (isError && (state.error ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.danger.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    state.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ],
              const Spacer(),
              if (incoming)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: <Widget>[
                    _LabelledButton(
                      label: callText(strings, 'call.decline', 'Decline'),
                      child: CallControlButton(
                        icon: Icons.call_end,
                        label: callText(strings, 'call.decline', 'Decline'),
                        background: theme.danger,
                        size: 68,
                        onPressed: widget.onDecline,
                      ),
                    ),
                    _LabelledButton(
                      label: callText(strings, 'call.accept', 'Accept'),
                      child: CallControlButton(
                        icon: state.kind == CallKind.audio
                            ? Icons.call
                            : Icons.videocam,
                        label: callText(strings, 'call.accept', 'Accept'),
                        background: _callGreen,
                        size: 68,
                        onPressed: widget.onAccept,
                      ),
                    ),
                  ],
                )
              else if (isError)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(140, 44),
                  ),
                  onPressed: widget.onDismiss,
                  child: Text(callText(strings, 'call.dismiss', 'Dismiss')),
                )
              else
                _LabelledButton(
                  label: callText(strings, 'call.cancel', 'Cancel'),
                  child: CallControlButton(
                    icon: Icons.call_end,
                    label: callText(strings, 'call.cancel', 'Cancel'),
                    background: theme.danger,
                    size: 68,
                    onPressed: widget.onCancel,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabelledButton extends StatelessWidget {
  const _LabelledButton({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        child,
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}

/// A ticking `mm:ss` since [since].
class CallElapsed extends StatefulWidget {
  const CallElapsed({super.key, required this.since, this.style});

  final int since;
  final TextStyle? style;

  @override
  State<CallElapsed> createState() => _CallElapsedState();
}

class _CallElapsedState extends State<CallElapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(widget.since),
    );
    return Text(formatCallClock(elapsed), style: widget.style);
  }
}

/// Shared frame of the active call: stage, status line, picture in picture,
/// notice banner and the control bar.
class _ActiveCallFrame extends StatelessWidget {
  const _ActiveCallFrame({
    required this.state,
    required this.status,
    required this.stage,
    required this.controls,
    this.pip,
    this.notice,
    this.onDismissNotice,
  });

  final CallSessionState state;
  final Widget status;
  final Widget stage;
  final Widget? pip;
  final List<Widget> controls;
  final String? notice;
  final VoidCallback? onDismissNotice;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    return _StageBackground(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          stage,
          SafeArea(
            child: Column(
              children: <Widget>[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _title(state, ChatUiScope.of(context).strings),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          DefaultTextStyle.merge(
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                            child: status,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Material(
                      color: theme.danger.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: onDismissNotice,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  notice!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.white,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 16,
                    runSpacing: 12,
                    children: controls,
                  ),
                ),
              ],
            ),
          ),
          if (pip != null)
            Positioned(
              top: 0,
              right: 12,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 76),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(width: 104, height: 148, child: pip),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A big avatar + name block used when there is no remote video to show.
class _AudioStage extends StatelessWidget {
  const _AudioStage({required this.name});
  final String? name;

  @override
  Widget build(BuildContext context) {
    return Center(child: CallAvatar(name: name, size: 140));
  }
}

/// Active peer to peer call.
class P2PActiveCallScreen extends StatelessWidget {
  const P2PActiveCallScreen({
    super.key,
    required this.state,
    required this.controller,
    required this.onHangup,
  });

  final CallSessionState state;
  final P2PCallController controller;
  final VoidCallback onHangup;

  @override
  Widget build(BuildContext context) {
    final scope = ChatUiScope.of(context);
    final strings = scope.strings;
    final theme = scope.theme;
    final snap = controller.snapshot;
    final video = state.kind == CallKind.video;

    Widget statusText;
    switch (snap.status) {
      case P2PStatus.connected:
        statusText = state.connectedAt == null
            ? Text(callText(strings, 'call.connected', 'Connected'))
            : CallElapsed(since: state.connectedAt!);
      case P2PStatus.reconnecting:
        statusText =
            Text(callText(strings, 'call.reconnecting', 'Reconnecting...'));
      case P2PStatus.waiting:
        statusText = Text(callText(strings, 'call.ringing', 'Ringing...'));
      default:
        statusText =
            Text(callText(strings, 'call.connecting', 'Connecting...'));
    }

    final remote = snap.remoteStream;
    final stage = video && remote != null && snap.remoteVideoLive
        ? RtcStreamView(stream: remote, revision: snap.remoteVideoLive ? 1 : 0)
        : _AudioStage(name: state.roomName);
    final local = snap.localStream;
    final pip = video && snap.camEnabled && local != null
        ? RtcStreamView(stream: local, mirror: true, revision: 1)
        : null;

    return _ActiveCallFrame(
      state: state,
      status: statusText,
      stage: stage,
      pip: pip,
      notice: snap.notice,
      onDismissNotice: controller.dismissNotice,
      controls: <Widget>[
        CallControlButton(
          icon: snap.micEnabled ? Icons.mic : Icons.mic_off,
          label: snap.micEnabled
              ? callText(strings, 'call.mute', 'Mute')
              : callText(strings, 'call.unmute', 'Unmute'),
          active: snap.micEnabled,
          onPressed: controller.toggleMic,
        ),
        if (video)
          CallControlButton(
            icon: snap.camEnabled ? Icons.videocam : Icons.videocam_off,
            label: snap.camEnabled
                ? callText(strings, 'call.cameraOff', 'Turn camera off')
                : callText(strings, 'call.cameraOn', 'Turn camera on'),
            active: snap.camEnabled,
            onPressed: () => unawaited(controller.toggleCamera()),
          ),
        if (video && snap.camEnabled)
          CallControlButton(
            icon: Icons.cameraswitch,
            label: callText(strings, 'call.flipCamera', 'Flip camera'),
            onPressed: () => unawaited(controller.flipCamera()),
          ),
        CallControlButton(
          icon: snap.speakerOn ? Icons.volume_up : Icons.volume_down,
          label: callText(strings, 'call.speaker', 'Speaker'),
          active: snap.speakerOn,
          onPressed: () => unawaited(controller.setSpeaker(!snap.speakerOn)),
        ),
        CallControlButton(
          icon: Icons.call_end,
          label: callText(strings, 'call.hangup', 'End call'),
          background: theme.danger,
          onPressed: onHangup,
        ),
      ],
    );
  }
}

/// Active LiveKit call (1:1 or group).
class LiveKitActiveCallScreen extends StatelessWidget {
  const LiveKitActiveCallScreen({
    super.key,
    required this.state,
    required this.session,
    required this.onHangup,
    this.showScreenShare = false,
  });

  final CallSessionState state;
  final LiveKitSession session;
  final VoidCallback onHangup;

  /// Offer the share-screen button (video calls only, like web).
  final bool showScreenShare;

  @override
  Widget build(BuildContext context) {
    final scope = ChatUiScope.of(context);
    final strings = scope.strings;
    final theme = scope.theme;
    final snap = session.snapshot;
    final video = state.kind == CallKind.video;
    final room = session is LiveKitRoomSession
        ? (session as LiveKitRoomSession).room
        : null;

    Widget statusText;
    if (!snap.connected) {
      statusText = Text(callText(strings, 'call.connecting', 'Connecting...'));
    } else if (snap.remoteCount == 0 && !state.isGroup) {
      statusText = Text(callText(strings, 'call.ringing', 'Ringing...'));
    } else if (state.connectedAt != null) {
      final people = state.isGroup && snap.remoteCount > 0
          ? ' - ${snap.remoteCount + 1}'
          : '';
      statusText = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CallElapsed(since: state.connectedAt!),
          if (people.isNotEmpty) Text(people),
        ],
      );
    } else {
      statusText = Text(callText(strings, 'call.connected', 'Connected'));
    }

    Widget stage;
    Widget? pip;
    if (room == null) {
      stage = _AudioStage(name: state.roomName);
    } else {
      stage = ListenableBuilder(
        listenable: room,
        builder: (context, _) {
          final remotes = room.remoteParticipants.values.toList();
          final screen = video ? remoteScreenShare(remotes) : null;
          if (screen != null) {
            return _ScreenShareStage(
              screen: screen,
              // In a group the other people stay visible under the screen.
              others: state.isGroup
                  ? <lk.Participant>[
                      ...remotes,
                      if (room.localParticipant != null) room.localParticipant!,
                    ]
                  : const <lk.Participant>[],
            );
          }
          if (state.isGroup) {
            return _GroupGrid(
              remotes: remotes,
              local: room.localParticipant,
            );
          }
          if (remotes.isEmpty) return _AudioStage(name: state.roomName);
          return video
              ? LiveKitParticipantTile(participant: remotes.first)
              : _AudioStage(name: state.roomName);
        },
      );
      final local = room.localParticipant;
      if (video && !state.isGroup && local != null && snap.camEnabled) {
        pip = LiveKitParticipantTile(participant: local, mirror: true);
      }
    }

    return _ActiveCallFrame(
      state: state,
      status: statusText,
      stage: stage,
      pip: pip,
      notice: snap.notice,
      onDismissNotice: session.dismissNotice,
      controls: <Widget>[
        CallControlButton(
          icon: snap.micEnabled ? Icons.mic : Icons.mic_off,
          label: snap.micEnabled
              ? callText(strings, 'call.mute', 'Mute')
              : callText(strings, 'call.unmute', 'Unmute'),
          active: snap.micEnabled,
          onPressed: () => unawaited(session.toggleMic()),
        ),
        if (video)
          CallControlButton(
            icon: snap.camEnabled ? Icons.videocam : Icons.videocam_off,
            label: snap.camEnabled
                ? callText(strings, 'call.cameraOff', 'Turn camera off')
                : callText(strings, 'call.cameraOn', 'Turn camera on'),
            active: snap.camEnabled,
            onPressed: () => unawaited(session.toggleCamera()),
          ),
        if (video && snap.camEnabled)
          CallControlButton(
            icon: Icons.cameraswitch,
            label: callText(strings, 'call.flipCamera', 'Flip camera'),
            onPressed: () => unawaited(session.flipCamera()),
          ),
        if (video && showScreenShare)
          CallControlButton(
            icon: snap.screenShareEnabled
                ? Icons.stop_screen_share
                : Icons.screen_share,
            label: snap.screenShareEnabled
                ? callText(strings, 'call.stopShare', 'Stop sharing')
                : callText(strings, 'call.shareScreen', 'Share screen'),
            active: !snap.screenShareEnabled,
            onPressed: () => unawaited(session.toggleScreenShare()),
          ),
        CallControlButton(
          icon: snap.speakerOn ? Icons.volume_up : Icons.volume_down,
          label: callText(strings, 'call.speaker', 'Speaker'),
          active: snap.speakerOn,
          onPressed: () => unawaited(session.setSpeaker(!snap.speakerOn)),
        ),
        CallControlButton(
          icon: Icons.call_end,
          label: callText(strings, 'call.hangup', 'End call'),
          background: theme.danger,
          onPressed: onHangup,
        ),
      ],
    );
  }
}

/// The first remote participant that is sharing their screen, or null.
lk.VideoTrack? remoteScreenShare(Iterable<lk.RemoteParticipant> remotes) {
  for (final participant in remotes) {
    for (final pub in participant.videoTrackPublications) {
      if (pub.source == lk.TrackSource.screenShareVideo &&
          !pub.muted &&
          pub.track != null) {
        return pub.track as lk.VideoTrack?;
      }
    }
  }
  return null;
}

/// A remote screen share fills the stage (uncropped); in a group the
/// participants stay in a strip beneath it.
class _ScreenShareStage extends StatelessWidget {
  const _ScreenShareStage({required this.screen, required this.others});

  final lk.VideoTrack screen;
  final List<lk.Participant> others;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: 84, bottom: others.isEmpty ? 110 : 8),
            child: ColoredBox(
              color: Colors.black,
              child: lk.VideoTrackRenderer(
                screen,
                fit: lk.VideoViewFit.contain,
                mirrorMode: lk.VideoViewMirrorMode.off,
              ),
            ),
          ),
        ),
        if (others.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 110),
            child: SizedBox(
              height: 92,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                children: <Widget>[
                  for (final p in others)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 92,
                        child: LiveKitParticipantTile(
                          key: ValueKey<String>(p.sid),
                          participant: p,
                          mirror: p is lk.LocalParticipant,
                          showName: true,
                          avatarSize: 40,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Group call layout: everyone in a grid sized to fill the stage, the local
/// tile last, the person speaking outlined. Scrolls when the tiles would be
/// too small to recognise anyone.
class _GroupGrid extends StatelessWidget {
  const _GroupGrid({required this.remotes, required this.local});

  final List<lk.RemoteParticipant> remotes;
  final lk.LocalParticipant? local;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      for (final p in remotes)
        LiveKitParticipantTile(
          key: ValueKey<String>(p.sid),
          participant: p,
          showName: true,
          avatarSize: 64,
          highlightSpeaking: true,
        ),
      if (local != null)
        LiveKitParticipantTile(
          key: const ValueKey<String>('local'),
          participant: local!,
          mirror: true,
          showName: true,
          avatarSize: 64,
          highlightSpeaking: true,
        ),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    // Room for the title bar above and the control bar below.
    return Padding(
      padding: const EdgeInsets.only(top: 84, bottom: 110),
      child: LayoutBuilder(
        builder: (context, box) {
          final plan = planGroupGrid(tiles.length, box.maxWidth, box.maxHeight);
          return GridView.count(
            crossAxisCount: plan.columns,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: plan.aspectRatio,
            padding: const EdgeInsets.all(4),
            physics: plan.scrolls
                ? const ClampingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            children: tiles,
          );
        },
      ),
    );
  }
}
