// The real [CallTonePlayer]: the bundled synthesised tones looped through
// audioplayers. Bytes come from the package assets, so the host app needs no
// asset declaration of its own.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import 'call_tones.dart';

const String _assetBase = 'packages/ethora_sdk_flutter/assets/calls';

class AudioplayersCallTonePlayer implements CallTonePlayer {
  AudioplayersCallTonePlayer();

  AudioPlayer? _player;
  final Map<CallTone, Uint8List> _bytes = <CallTone, Uint8List>{};

  AudioPlayer get _ensure =>
      _player ??= AudioPlayer(playerId: 'ethora_call_tone');

  Future<Uint8List> _load(CallTone tone) async {
    final cached = _bytes[tone];
    if (cached != null) return cached;
    final data = await rootBundle.load('$_assetBase/${tone.name}.wav');
    return _bytes[tone] = data.buffer.asUint8List();
  }

  @override
  Future<void> play(CallTone tone, {required bool speaker}) async {
    final bytes = await _load(tone);
    final player = _ensure;
    await player.stop();
    await player.setAudioContext(
      AudioContextConfig(
        route: speaker
            ? AudioContextConfigRoute.speaker
            : AudioContextConfigRoute.earpiece,
        focus: AudioContextConfigFocus.gain,
        respectSilence: false,
        stayAwake: false,
      ).build(),
    );
    await player.setReleaseMode(ReleaseMode.loop);
    await player.setVolume(1);
    await player.play(BytesSource(bytes, mimeType: 'audio/wav'));
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
  }

  @override
  Future<void> dispose() async {
    final player = _player;
    _player = null;
    await player?.dispose();
  }
}
