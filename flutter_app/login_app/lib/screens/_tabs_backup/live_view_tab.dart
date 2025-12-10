import 'package:flutter/material.dart';
import '../../services/doorbell_service.dart';

class LiveViewTab extends StatefulWidget {
  final DoorbellService doorbellService;

  const LiveViewTab({super.key, required this.doorbellService});

  @override
  State<LiveViewTab> createState() => _LiveViewTabState();
}

class _LiveViewTabState extends State<LiveViewTab> {
  bool _isUnlocking = false;
  bool _isPlayingMessage = false;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Live View Placeholder
          Container(
            height: 300,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.videocam_off, size: 48, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('Live View (ESP32-CAM Stream)',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Snapshot Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Snapshot captured!')),
                );
              },
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take Snapshot'),
            ),
          ),
          const SizedBox(height: 12),

          // Remote Unlock Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isUnlocking
                  ? null
                  : () async {
                      setState(() => _isUnlocking = true);
                      await widget.doorbellService.remoteUnlock();
                      setState(() => _isUnlocking = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Door unlocked!')),
                      );
                    },
              icon: _isUnlocking
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.lock_open),
              label: const Text('Remote Unlock'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Play Message Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isPlayingMessage
                  ? null
                  : () async {
                      setState(() => _isPlayingMessage = true);
                      await widget.doorbellService.playMessage('default');
                      setState(() => _isPlayingMessage = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Pre-recorded message played!')),
                      );
                    },
              icon: _isPlayingMessage
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.speaker),
              label: const Text('Play Pre-Recorded Message'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Status Info
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Doorbell Status',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Connection:'),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('Online',
                          style: TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Battery:'),
                    Text('85%'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}