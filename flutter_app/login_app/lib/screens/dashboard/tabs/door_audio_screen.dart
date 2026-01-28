import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:web_socket_channel/io.dart';

class DoorAudioScreen extends StatefulWidget {
  const DoorAudioScreen({super.key});

  @override
  State<DoorAudioScreen> createState() => _DoorAudioScreenState();
}

class _DoorAudioScreenState extends State<DoorAudioScreen> {
  // ====== SET YOUR ESP IP HERE IN VS CODE ======
  static const String _espIp = '132.68.34.61';

  // Must match ESP: PCM16 LE, mono, 16kHz
  static const int _sampleRate = 16000;

  // Keep a small jitter buffer
  static const int _maxBufferedSamples = _sampleRate * 2; // ~2s safety cap
  static const int _feedChunk = 1024;

  // =======================
  // ESP MIC -> PHONE (RX)
  // =======================
  IOWebSocketChannel? _wsRx;
  StreamSubscription? _wsRxSub;

  bool _isListening = false;
  bool _isRxConnecting = false;

  String _rxStatus = 'idle';
  int _rxBytes = 0;
  int _rxPackets = 0;

  final List<int> _sampleBuffer = <int>[];

  bool _pcmInitialized = false;
  bool _pcmStarted = false;

  String _wsRxUrl() => 'ws://$_espIp:81/ws_audio';

  // ==========================
  // PHONE MIC -> ESP SPEAKER
  // ==========================
  static const MethodChannel _mc = MethodChannel('doorbell/mic_stream');
  static const EventChannel _statusEc = EventChannel('doorbell/mic_stream_events');
  static const EventChannel _pcmEc = EventChannel('doorbell/mic_pcm');

  StreamSubscription? _nativeStatusSub;
  StreamSubscription? _nativePcmSub;

  IOWebSocketChannel? _wsSpeak;
  StreamSubscription? _wsSpeakSub;

  bool _isSpeaking = false;
  bool _isSpeakConnecting = false;
  String _speakStatus = 'idle';

  int _txBytes = 0;
  int _txPackets = 0;

  String _wsSpeakUrl() => 'ws://$_espIp:81/ws_speak';

  @override
  void initState() {
    super.initState();
    _initPcmOnce();

    // Native status events (permission, recording, errors)
    _nativeStatusSub = _statusEc.receiveBroadcastStream().listen((event) {
      final s = event?.toString() ?? '';
      if (!mounted) return;

      setState(() {
        if (s == 'permission_request') _speakStatus = 'requesting mic permission...';
        else if (s == 'permission_granted') _speakStatus = 'mic permission granted';
        else if (s == 'permission_denied') {
          _speakStatus = 'mic permission denied';
          _isSpeaking = false;
          _isSpeakConnecting = false;
        } else if (s == 'starting') _speakStatus = 'starting mic...';
        else if (s == 'recording') {
          _speakStatus = 'speaking';
          _isSpeaking = true;
          _isSpeakConnecting = false;
        } else if (s == 'recording_stopped' || s == 'stopped') {
          _speakStatus = 'stopped';
          _isSpeaking = false;
          _isSpeakConnecting = false;
        } else if (s.startsWith('error:')) {
          _speakStatus = 'ERROR ${s.substring(6)}';
          _isSpeaking = false;
          _isSpeakConnecting = false;
        }
      });
    });

    // Native PCM stream -> send to ESP ws_speak
    _nativePcmSub = _pcmEc.receiveBroadcastStream().listen((event) {
      if (!_isSpeaking) return;
      final ws = _wsSpeak;
      if (ws == null) return;

      Uint8List bytes;
      if (event is Uint8List) {
        bytes = event;
      } else if (event is List<int>) {
        bytes = Uint8List.fromList(event);
      } else {
        return;
      }

      try {
        ws.sink.add(bytes);
        _txBytes += bytes.length;
        _txPackets += 1;
        if ((_txPackets % 30) == 0 && mounted) setState(() {});
      } catch (_) {
        // ignore; ws onError/onDone will handle
      }
    });
  }

  // ---------- PCM playback engine (for RX) ----------
  Future<void> _initPcmOnce() async {
    if (_pcmInitialized) return;

    try {
      await FlutterPcmSound.setLogLevel(LogLevel.error);
      await FlutterPcmSound.setup(sampleRate: _sampleRate, channelCount: 1);

      await FlutterPcmSound.setFeedThreshold(_sampleRate ~/ 8); // ~125ms
      FlutterPcmSound.setFeedCallback(_onFeed);

      _pcmInitialized = true;
      FlutterPcmSound.start(); // keep alive
      _pcmStarted = true;
    } catch (e) {
      if (mounted) setState(() => _rxStatus = 'PCM init failed');
      _showSnack('PCM init failed: $e');
    }
  }

  Future<void> _onFeed(int remainingFrames) async {
    if (!_pcmInitialized) return;

    if (!_isListening) {
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(List<int>.filled(160, 0)));
      return;
    }

    final int available = _sampleBuffer.length;
    if (available == 0) {
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(List<int>.filled(160, 0)));
      return;
    }

    final int n = (available < _feedChunk) ? available : _feedChunk;
    final chunk = _sampleBuffer.sublist(0, n);
    _sampleBuffer.removeRange(0, n);

    await FlutterPcmSound.feed(PcmArrayInt16.fromList(chunk));
  }

  void _pushSamplesFromBytes(Uint8List bytes) {
    if (bytes.lengthInBytes < 2) return;
    final int usable = bytes.lengthInBytes & ~1; // even length
    final view = Int16List.view(bytes.buffer, bytes.offsetInBytes, usable ~/ 2);
    _sampleBuffer.addAll(view);

    if (_sampleBuffer.length > _maxBufferedSamples) {
      _sampleBuffer.removeRange(0, _sampleBuffer.length - _maxBufferedSamples);
    }
  }

  // ---------- RX controls ----------
  Future<void> _startListening() async {
    if (_isListening || _isRxConnecting) return;

    await _initPcmOnce();
    if (!_pcmInitialized) return;

    setState(() {
      _isRxConnecting = true;
      _rxStatus = 'connecting...';
      _rxBytes = 0;
      _rxPackets = 0;
    });

    await _closeWsRx();

    try {
      _sampleBuffer.clear();

      _wsRx = IOWebSocketChannel.connect(
        Uri.parse(_wsRxUrl()),
        pingInterval: const Duration(seconds: 3),
      );

      _wsRxSub = _wsRx!.stream.listen(
        (data) {
          Uint8List bytes;
          if (data is Uint8List) bytes = data;
          else if (data is List<int>) bytes = Uint8List.fromList(data);
          else return;

          _rxBytes += bytes.length;
          _rxPackets += 1;

          _pushSamplesFromBytes(bytes);

          if ((_rxPackets % 20) == 0 && mounted) setState(() {});
        },
        onError: (e) {
          _showSnack('Audio WS error: $e');
          _stopListening();
        },
        onDone: () => _stopListening(),
      );

      if (!mounted) return;
      setState(() {
        _isListening = true;
        _isRxConnecting = false;
        _rxStatus = 'listening';
      });

      if (!_pcmStarted) {
        FlutterPcmSound.start();
        _pcmStarted = true;
      }
    } catch (e) {
      _showSnack('Failed to connect audio: $e');
      await _closeWsRx();
      if (mounted) {
        setState(() {
          _isRxConnecting = false;
          _isListening = false;
          _rxStatus = 'stopped';
        });
      }
    }
  }

  Future<void> _stopListening() async {
    if (!_isListening && !_isRxConnecting) return;

    setState(() {
      _isListening = false;
      _isRxConnecting = false;
      _rxStatus = 'stopped';
    });

    _sampleBuffer.clear();
    await _closeWsRx();
  }

  Future<void> _closeWsRx() async {
    try { await _wsRxSub?.cancel(); } catch (_) {}
    _wsRxSub = null;

    try { _wsRx?.sink.close(1000); } catch (_) {}
    _wsRx = null;
  }

  // ---------- Speak (TX) controls ----------
  Future<void> _startSpeaking() async {
    if (_isSpeaking || _isSpeakConnecting) return;

    setState(() {
      _isSpeakConnecting = true;
      _speakStatus = 'connecting...';
      _txBytes = 0;
      _txPackets = 0;
    });

    await _closeWsSpeak();

    try {
      // 1) connect WS to ESP speaker endpoint
      _wsSpeak = IOWebSocketChannel.connect(
        Uri.parse(_wsSpeakUrl()),
        pingInterval: const Duration(seconds: 3),
      );

      _wsSpeakSub = _wsSpeak!.stream.listen(
        (_) {},
        onError: (e) {
          _showSnack('Speak WS error: $e');
          _stopSpeaking();
        },
        onDone: () => _stopSpeaking(),
      );

      // 2) start native mic stream (permission handled in Android)
      final ok = await _mc.invokeMethod<bool>('startMic');
      if (ok != true) {
        // waiting for permission or failed
        if (mounted) {
          setState(() {
            _isSpeakConnecting = false;
            _isSpeaking = false;
            _speakStatus = 'waiting for mic permission...';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            // actual "speaking" will flip when status event says "recording"
            _speakStatus = 'mic starting...';
          });
        }
      }
    } catch (e) {
      await _closeWsSpeak();
      if (!mounted) return;
      setState(() {
        _isSpeakConnecting = false;
        _isSpeaking = false;
        _speakStatus = 'ERROR $e';
      });
      _showSnack('Speak start failed: $e');
    }
  }

  Future<void> _stopSpeaking() async {
    try { await _mc.invokeMethod('stopMic'); } catch (_) {}

    await _closeWsSpeak();

    if (!mounted) return;
    setState(() {
      _isSpeaking = false;
      _isSpeakConnecting = false;
      _speakStatus = 'stopped';
    });
  }

  Future<void> _closeWsSpeak() async {
    try { await _wsSpeakSub?.cancel(); } catch (_) {}
    _wsSpeakSub = null;

    try { _wsSpeak?.sink.close(1000); } catch (_) {}
    _wsSpeak = null;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _stopListening();
    _stopSpeaking();
    _nativeStatusSub?.cancel();
    _nativePcmSub?.cancel();

    FlutterPcmSound.setFeedCallback(null);
    FlutterPcmSound.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rxIcon = _isListening ? Icons.hearing : Icons.hearing_disabled;
    final rxColor =
        _isListening ? Colors.deepPurple : (_isRxConnecting ? Colors.orange : Colors.grey);

    final txIcon = _isSpeaking ? Icons.mic : Icons.mic_none;
    final txColor =
        _isSpeaking ? Colors.green : (_isSpeakConnecting ? Colors.orange : Colors.grey);

    final rxKb = (_rxBytes / 1024.0);
    final rxText = (_isListening || _isRxConnecting)
        ? 'Received: ${rxKb.toStringAsFixed(1)} KB ($_rxPackets packets)'
        : 'Received: 0 KB';

    final txKb = (_txBytes / 1024.0);
    final txText = (_isSpeaking || _isSpeakConnecting)
        ? 'Sent: ${txKb.toStringAsFixed(1)} KB ($_txPackets packets)'
        : 'Sent: 0 KB';

    return Scaffold(
      appBar: AppBar(title: const Text('Door Audio')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),

            // ===== RX =====
            Icon(rxIcon, size: 72, color: rxColor),
            const SizedBox(height: 8),
            Text('Listen status: $_rxStatus',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 6),
            Text(rxText,
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isListening ? _stopListening : _startListening,
              icon: Icon(_isListening ? Icons.stop : Icons.play_arrow),
              label: Text(_isListening ? 'Stop listening' : 'Start listening'),
            ),

            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 14),

            // ===== TX =====
            Icon(txIcon, size: 72, color: txColor),
            const SizedBox(height: 8),
            Text('Speak status: $_speakStatus',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 6),
            Text(txText,
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isSpeaking ? _stopSpeaking : _startSpeaking,
              icon: Icon(_isSpeaking ? Icons.stop : Icons.mic),
              label: Text(_isSpeaking ? 'Stop speaking' : 'Start speaking'),
            ),

            const SizedBox(height: 14),
            const Text(
              'This version DOES NOT need OkHttp/Okio.\n'
              'Native side only captures mic PCM, Dart sends it to ws_speak.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
