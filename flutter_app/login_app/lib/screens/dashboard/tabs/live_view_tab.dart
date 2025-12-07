import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

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

  // 👇 ESP32-S3 camera IP
  static const String _cameraUrl = 'http://132.68.34.61';

  void _showSnack(String text) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(text)));
    });
  }

  Future<void> _openLiveView() async {
    final uri = Uri.parse(_cameraUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      _showSnack('Could not open live view ($_cameraUrl)');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // LIVE VIEW BOX – tap to open ESP32 page
          GestureDetector(
            onTap: _openLiveView,
            child: Container(
              height: 300,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.videocam, size: 48, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      'Tap to open Live View\n(ESP32-CAM at 132.68.34.61)',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Extra explicit button to open live view
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _openLiveView,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open Live View (132.68.34.61)'),
            ),
          ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _showSnack('Snapshot captured!'),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take Snapshot'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isUnlocking
                  ? null
                  : () async {
                      setState(() => _isUnlocking = true);
                      await widget.doorbellService.remoteUnlock();
                      if (!mounted) return;
                      setState(() => _isUnlocking = false);
                      _showSnack('Door unlocked!');
                    },
              icon: _isUnlocking
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isPlayingMessage
                  ? null
                  : () async {
                      setState(() => _isPlayingMessage = true);
                      await widget.doorbellService.playMessage('default');
                      if (!mounted) return;
                      setState(() => _isPlayingMessage = false);
                      _showSnack('Pre-recorded message played!');
                    },
              icon: _isPlayingMessage
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Doorbell Status',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Connection:'),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Online',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
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
