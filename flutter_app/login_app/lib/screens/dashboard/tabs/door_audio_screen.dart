import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:firebase_database/firebase_database.dart';

class DoorAudioScreen extends StatefulWidget {
  const DoorAudioScreen({super.key});

  @override
  State<DoorAudioScreen> createState() => _DoorAudioScreenState();
}

class _DoorAudioScreenState extends State<DoorAudioScreen> {
  // 👇 CHANGE THIS every time the ESP32 IP changes
  static const String _wsUrl = 'ws://132.68.34.63:81/audio';

  WebSocketChannel? _channel;
  bool _isListening = false;
  int _bytesReceived = 0;

  // Firebase Realtime Database path: /doorAudio/lastSession
  final DatabaseReference _dbRef =
      FirebaseDatabase.instance.ref('doorAudio/lastSession');

  void _startListening() {
    if (_isListening) return;

    try {
      debugPrint('Connecting to $_wsUrl');
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _bytesReceived = 0;

      _channel!.stream.listen(
        (data) {
          int added = 0;

          if (data is Uint8List) {
            added = data.length;
          } else if (data is List<int>) {
            added = data.length;
          } else {
            debugPrint('Unexpected data type: ${data.runtimeType}');
          }

          if (added > 0) {
            setState(() {
              _bytesReceived += added;
            });

            // 🔥 write to Firebase so you can see it there
            _dbRef.set({
              'bytes': _bytesReceived,
              'updatedAt': ServerValue.timestamp,
            });
          }
        },
        onError: (error) {
          debugPrint('WebSocket error: $error');
          setState(() {
            _isListening = false;
          });
        },
        onDone: () {
          debugPrint(
              'WebSocket closed (done), code: ${_channel?.closeCode}, reason: ${_channel?.closeReason}');
          setState(() {
            _isListening = false;
          });
        },
      );

      setState(() {
        _isListening = true;
      });
    } catch (e) {
      debugPrint('Failed to connect WebSocket: $e');
    }
  }

  void _stopListening() {
    _channel?.sink.close();
    _channel = null;
    setState(() {
      _isListening = false;
    });
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = _isListening ? Icons.hearing : Icons.hearing_disabled;
    final color = _isListening ? Colors.deepPurple : Colors.grey;
    final title = _isListening
        ? 'Listening to door…'
        : 'Tap the button to start listening';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Door Microphone'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 80, color: color),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text('Bytes received: $_bytesReceived'),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isListening ? _stopListening : _startListening,
              child: Text(_isListening ? 'Stop listening' : 'Listen to door'),
            ),
          ],
        ),
      ),
    );
  }
}
