import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database/ui/firebase_animated_list.dart';
import 'package:flutter/material.dart';
import '../../../services/doorbell_service.dart';

class NotificationsTab extends StatefulWidget {
  final DoorbellService doorbellService;
  const NotificationsTab({super.key, required this.doorbellService});

  @override
  State<NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<NotificationsTab> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // Simple in-memory cache for snapshot images
  final Map<String, String?> _snapshotB64Cache = {};

  String _formatTs(dynamic ts) {
    final int? ms = ts is int ? ts : int.tryParse(ts?.toString() ?? '');
    if (ms == null) return "Unknown time";
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} "
        "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}";
  }

  Future<String?> _getSnapshotBase64(String snapshotKey) async {
    // cache hit
    if (_snapshotB64Cache.containsKey(snapshotKey)) {
      return _snapshotB64Cache[snapshotKey];
    }

    try {
      final snap = await _db.child('snapshots/$snapshotKey/image').get();
      final val = snap.value?.toString();
      _snapshotB64Cache[snapshotKey] = val;
      return val;
    } catch (_) {
      _snapshotB64Cache[snapshotKey] = null;
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _db
        .child('notifications')
        .orderByChild('ts')
        .limitToLast(50);

    return Scaffold(
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              "Notifications",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: FirebaseAnimatedList(
              query: query,
              sort: (a, b) {
                // newest first by ts if possible
                final aMap = a.value is Map ? (a.value as Map) : {};
                final bMap = b.value is Map ? (b.value as Map) : {};
                final aTs = aMap['ts'];
                final bTs = bMap['ts'];
                final aMs = aTs is int ? aTs : int.tryParse(aTs?.toString() ?? '') ?? 0;
                final bMs = bTs is int ? bTs : int.tryParse(bTs?.toString() ?? '') ?? 0;
                return bMs.compareTo(aMs);
              },
              itemBuilder: (context, snapshot, animation, index) {
                final val = snapshot.value;

                // Be robust: if someone pushed plain string, handle it.
                String type = "unknown";
                dynamic ts;
                String? snapshotKey;

                if (val is Map) {
                  type = (val['type'] ?? 'unknown').toString();
                  ts = val['ts'];
                  snapshotKey = val['snapshotKey']?.toString();
                } else {
                  type = val?.toString() ?? "unknown";
                }

                final title = (type == "ring")
                    ? "Doorbell pressed"
                    : "Notification: $type";

                return SizeTransition(
                  sizeFactor: animation,
                  child: Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            backgroundColor: (type == "ring") ? Colors.blue : Colors.grey,
                            child: Icon(
                              (type == "ring") ? Icons.notifications_active : Icons.notifications,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Text("Time: ${_formatTs(ts)}",
                                    style: const TextStyle(color: Colors.grey)),
                                const SizedBox(height: 8),

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
                                        return Container(
                                          height: 140,
                                          width: double.infinity,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: Colors.black12,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: const Text("Snapshot not available"),
                                        );
                                      }

                                      try {
                                        final bytes = base64Decode(b64);
                                        return ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: Image.memory(
                                            bytes,
                                            height: 180,
                                            width: double.infinity,
                                            fit: BoxFit.cover,
                                          ),
                                        );
                                      } catch (_) {
                                        return const Text("Snapshot decode failed");
                                      }
                                    },
                                  ),
                              ],
                            ),
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
