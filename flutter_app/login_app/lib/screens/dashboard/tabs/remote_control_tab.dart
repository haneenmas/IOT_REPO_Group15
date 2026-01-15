import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../../services/doorbell_service.dart';

class RemoteControlTab extends StatefulWidget {
  final DoorbellService doorbellService;
  const RemoteControlTab({super.key, required this.doorbellService});

  @override
  State<RemoteControlTab> createState() => _RemoteControlTabState();
}

class _RemoteControlTabState extends State<RemoteControlTab> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  // ----------------------------
  // Door commands
  // ----------------------------
  Future<void> _sendDoorCommand(String cmd) async {
    try {
      await _dbRef.child('door_command').set(cmd);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Command sent: $cmd')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send command: $e')),
      );
    }
  }

  // ----------------------------
  // Audio controls (matches Firebase structure)
  // /audio/active   (bool)
  // /audio/volume   (int 0..10)
  // /audio/command  (string) "NONE" | "STOP" | "<messageKey>"
  // /audio/messages/<key>/{enabled,title,file}
  // ----------------------------
  Future<void> _setAudioActive(bool active) async {
    try {
      await _dbRef.child('audio/active').set(active);
    } catch (_) {}
  }

  Future<void> _setAudioVolume(int vol) async {
    try {
      await _dbRef.child('audio/volume').set(vol);
    } catch (_) {}
  }

  Future<void> _sendAudioCommand(String cmd) async {
    try {
      await _dbRef.child('audio/command').set(cmd);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Audio command: $cmd')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send audio command: $e')),
      );
    }
  }

  Future<void> _playAudio(String messageKey) async {
    await _setAudioActive(true);
    await _sendAudioCommand(messageKey);
  }

  Future<void> _stopAudio() async {
    await _sendAudioCommand("STOP");
  }

  @override
  void initState() {
    super.initState();

    // ✅ Android stability: ensure RTDB connection is online when tab initializes
    FirebaseDatabase.instance.goOnline();

    // Your existing behavior (keep)
    _setAudioActive(true);
  }

  @override
  void dispose() {
    // Keep your behavior
    _setAudioActive(false);
    super.dispose();
  }

  // Build audio buttons from /audio/messages
  Widget _buildAudioButtonsFromFirebase() {
    return StreamBuilder<DatabaseEvent>(
      stream: _dbRef.child('audio/messages').onValue,
      builder: (context, snapshot) {
        final value = snapshot.data?.snapshot.value;

        if (value == null || value is! Map) {
          return const Text(
            "No audio messages found.\nAdd them in Firebase under /audio/messages",
            textAlign: TextAlign.center,
          );
        }

        final map = Map<dynamic, dynamic>.from(value);
        final keys = map.keys.map((e) => e.toString()).toList()..sort();

        if (keys.isEmpty) {
          return const Text("No audio messages found in /audio/messages");
        }

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final k in keys)
              Builder(
                builder: (_) {
                  final raw = map[k];
                  if (raw == null || raw is! Map) {
                    return ElevatedButton(
                      onPressed: null,
                      child: Text(k),
                    );
                  }

                  final m = Map<dynamic, dynamic>.from(raw);
                  final bool enabled = (m['enabled'] == true);
                  final String title =
                  (m['title'] != null ? m['title'].toString() : k);
                  final String file =
                  (m['file'] != null ? m['file'].toString() : "");

                  return ElevatedButton(
                    onPressed: enabled ? () => _playAudio(k) : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, textAlign: TextAlign.center),
                        if (file.isNotEmpty)
                          Text(
                            file,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.black54,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildAudioControls() {
    return StreamBuilder<DatabaseEvent>(
      stream: _dbRef.child('audio').onValue,
      builder: (context, snapshot) {
        bool active = true;
        int volume = 10;
        String cmd = "NONE";

        final v = snapshot.data?.snapshot.value;
        if (v is Map) {
          final m = Map<dynamic, dynamic>.from(v);
          active = (m['active'] == true);
          cmd = (m['command'] ?? "NONE").toString();

          final rawVol = m['volume'];
          if (rawVol is int) volume = rawVol.clamp(0, 10);
          if (rawVol is String) {
            final parsed = int.tryParse(rawVol);
            if (parsed != null) volume = parsed.clamp(0, 10);
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("Audio Enabled"),
              value: active,
              onChanged: (v) => _setAudioActive(v),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Text("Volume"),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: volume.toString(),
                    value: volume.toDouble(),
                    onChanged: (val) => _setAudioVolume(val.round()),
                  ),
                ),
                Text(volume.toString()),
              ],
            ),
            Text(
              "Status: active=$active | cmd=$cmd",
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          StreamBuilder<DatabaseEvent>(
            stream: _dbRef.child('door_status').onValue,
            builder: (context, snapshot) {
              String status = "Unknown";
              if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                status = snapshot.data!.snapshot.value.toString();
              }
              final bool isOpen = (status == "Open");
              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isOpen ? Colors.green.shade100 : Colors.red.shade100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isOpen ? Colors.green : Colors.red),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isOpen ? Icons.lock_open : Icons.lock,
                      color: isOpen ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      "Door is $status",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color:
                        isOpen ? Colors.green.shade900 : Colors.red.shade900,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _sendDoorCommand("LOCK"),
                  icon: const Icon(Icons.lock),
                  label: const Text("Lock"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _sendDoorCommand("UNLOCK"),
                  icon: const Icon(Icons.lock_open),
                  label: const Text("Unlock"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),

          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "Pre-Recorded Messages",
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 10),

          _buildAudioControls(),
          const SizedBox(height: 12),

          _buildAudioButtonsFromFirebase(),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _stopAudio,
                  icon: const Icon(Icons.stop),
                  label: const Text("Stop Audio"),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          StreamBuilder<DatabaseEvent>(
            stream: _dbRef.child('door_command').onValue,
            builder: (context, snapshot) {
              String cmd = "NONE";
              if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                cmd = snapshot.data!.snapshot.value.toString();
              }
              return Text(
                "Last door command: $cmd",
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              );
            },
          ),
        ],
      ),
    );
  }
}
