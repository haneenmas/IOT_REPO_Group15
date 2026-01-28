import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Optional helper (you can keep it or ignore it).
/// Plays PCM16 LE mono 16kHz from ws://<ip>:81/ws_audio
class LanAudioStreamPlayer {
  static const int sampleRate = 16000;

  WebSocketChannel? _ws;
  StreamSubscription? _sub;

  final List<int> _buffer = <int>[];
  bool _ready = false;
  bool _playing = false;

  Future<void> _ensureReady() async {
    if (_ready) return;
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 8);
    FlutterPcmSound.setFeedCallback(_onFeed);
    _ready = true;
  }

  Future<void> _onFeed(int remainingFrames) async {
    if (!_playing) return;
    if (_buffer.isEmpty) {
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(List<int>.filled(160, 0)));
      return;
    }

    const int want = 1024;
    final int n = (_buffer.length < want) ? _buffer.length : want;
    final chunk = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    await FlutterPcmSound.feed(PcmArrayInt16.fromList(chunk));
  }

  void _pushBytes(Uint8List bytes) {
    final usable = bytes.lengthInBytes & ~1;
    if (usable < 2) return;
    final view = Int16List.view(bytes.buffer, bytes.offsetInBytes, usable ~/ 2);
    _buffer.addAll(view);
    if (_buffer.length > sampleRate * 2) {
      _buffer.removeRange(0, _buffer.length - sampleRate * 2);
    }
  }

  Future<void> start(String ip) async {
    await _ensureReady();

    final url = 'ws://$ip:81/ws_audio';
    _ws = WebSocketChannel.connect(Uri.parse(url));
    _sub = _ws!.stream.listen((data) {
      if (data is Uint8List) _pushBytes(data);
      else if (data is List<int>) _pushBytes(Uint8List.fromList(data));
    });

    _playing = true;
    FlutterPcmSound.start();
  }

  Future<void> stop() async {
    _playing = false;
    _sub?.cancel();
    _sub = null;
    _ws?.sink.close();
    _ws = null;

    FlutterPcmSound.setFeedCallback(null);
    await FlutterPcmSound.release();
    _ready = false;
    _buffer.clear();
  }
}
