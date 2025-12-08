import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart'; // Ensure this is imported

import '../../../services/doorbell_service.dart';

class LiveViewTab extends StatefulWidget {
  final DoorbellService doorbellService;
  const LiveViewTab({super.key, required this.doorbellService});

  @override
  State<LiveViewTab> createState() => _LiveViewTabState();
}


class _LiveViewTabState extends State<LiveViewTab> {
  bool _isUnlocking = false;
  bool _isPlayingMessage = false;

  // 🔴 IMPORTANT: This must match your ESP32 IP exactly
  // Port 81 is standard for the video stream
  final String _streamUrl = 'http://192.168.1.22:81/stream';

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // LIVE VIDEO BOX
          Container(
            height: 300,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Mjpeg(
                isLive: true,
                stream: _streamUrl,
                timeout: const Duration(seconds: 10), // Retry if connection drops
                loading: (context) => const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 10),
                      Text("Connecting to Doorbell...", 
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
                error: (context, error, stack) => const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.videocam_off, color: Colors.white54, size: 48),
                      Text("Stream Offline", style: TextStyle(color: Colors.white54)),
                      Text("Check if ESP32 is powered on", 
                          style: TextStyle(color: Colors.white24, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 24),

          // EXISTING CONTROLS
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Snapshot captured!'))
                );
              },
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take Snapshot'),
            ),
          ),
          
          const SizedBox(height: 12),
          
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isUnlocking ? null : () async {
                setState(() => _isUnlocking = true);
                // Simulate delay or call your actual service
                await Future.delayed(const Duration(seconds: 2)); 
                if (mounted) {
                  setState(() => _isUnlocking = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Door unlocked!'))
                  );
                }
              },
              icon: _isUnlocking
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.lock_open),
              label: const Text('Remote Unlock'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isPlayingMessage ? null : () async {
                 setState(() => _isPlayingMessage = true);
                 await Future.delayed(const Duration(seconds: 2));
                 if (mounted) {
                   setState(() => _isPlayingMessage = false);
                   ScaffoldMessenger.of(context).showSnackBar(
                     const SnackBar(content: Text('Message Played!'))
                   );
                 }
              },
              icon: _isPlayingMessage
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.speaker),
              label: const Text('Play Pre-Recorded Message'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}