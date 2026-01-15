import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database/ui/firebase_animated_list.dart';
import 'package:flutter/material.dart';
import '../../../services/doorbell_service.dart';

class HistoryTab extends StatefulWidget {
  final DoorbellService doorbellService;
  const HistoryTab({super.key, required this.doorbellService});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  final Map<String, String?> _snapshotB64Cache = {};

  String _formatTs(dynamic ts) {
    final int? ms = ts is int ? ts : int.tryParse(ts?.toString() ?? '');
    if (ms == null) return "Unknown time";
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} "
        "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}";
  }

  Future<String?> _getSnapshotBase64(String snapshotKey) async {
    if (_snapshotB64Cache.containsKey(snapshotKey)) {
      return _snapshotB64Cache[snapshotKey];
    }
    try {
      final snap = await _dbRef.child('snapshots/$snapshotKey/image').get();
      final val = snap.value?.toString();
      _snapshotB64Cache[snapshotKey] = val;
      return val;
    } catch (_) {
      _snapshotB64Cache[snapshotKey] = null;
      return null;
    }
  }

  @override
  void dispose() {
    _snapshotB64Cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _dbRef.child('history').orderByChild('ts').limitToLast(80);

    return Scaffold(
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              "Recent Activity",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: FirebaseAnimatedList(
              query: query,
              reverse: true, // ✅ newest first (no custom sort)
              itemBuilder: (context, snapshot, animation, index) {
                final val = snapshot.value;

                String title = "Event";
                String subtitle = "";
                IconData icon = Icons.history;
                Color color = Colors.grey;

                String? snapshotKey;

                if (val is Map) {
                  final action = (val['action'] ?? 'unknown').toString();
                  final by = (val['by'] ?? 'Unknown').toString();
                  final ts = val['ts'];

                  snapshotKey = val['snapshotKey']?.toString();

                  if (action == "ring") {
                    title = "Doorbell pressed";
                    icon = Icons.notifications_active;
                    color = Colors.blue;
                  } else if (action == "unlock") {
                    title = "Door unlocked";
                    icon = Icons.lock_open;
                    color = Colors.green;
                  } else {
                    title = "Action: $action";
                    icon = Icons.event;
                    color = Colors.grey;
                  }

                  subtitle = "By: $by • Time: ${_formatTs(ts)}";
                } else {
                  title = val?.toString() ?? "Unknown";
                  subtitle = "Legacy history entry";
                  icon = Icons.history;
                  color = Colors.grey;
                }

                return SizeTransition(
                  sizeFactor: animation,
                  child: Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundColor: color,
                              child: Icon(icon, color: Colors.white),
                            ),
                            title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text(subtitle),
                            trailing: const Icon(Icons.access_time, size: 16),
                          ),
                          if (snapshotKey != null && snapshotKey.isNotEmpty)
                            FutureBuilder<String?>(
                              future: _getSnapshotBase64(snapshotKey),
                              builder: (context, snapB64) {
                                if (!snapB64.hasData) {
                                  return Container(
                                    height: 140,
                                    width: double.infinity,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: Colors.black12,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const CircularProgressIndicator(),
                                  );
                                }

                                final b64 = snapB64.data;
                                if (b64 == null || b64.isEmpty) {
                                  return const SizedBox.shrink();
                                }

                                try {
                                  final bytes = base64Decode(b64);
                                  return Padding(
                                    padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Image.memory(
                                        bytes,
                                        height: 180,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  );
                                } catch (_) {
                                  return const Padding(
                                    padding: EdgeInsets.only(left: 8, right: 8, bottom: 8),
                                    child: Text("Snapshot decode failed"),
                                  );
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
