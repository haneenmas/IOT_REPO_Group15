import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';

class DoorbellEvent {
  final String id;
  final String type; // 'snapshot', 'motion', 'unlock', 'failed_code', 'message'
  final DateTime timestamp;
  final String? mediaUrl;
  final String? description;

  DoorbellEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    this.mediaUrl,
    this.description,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'timestamp': timestamp.toIso8601String(),
        'mediaUrl': mediaUrl,
        'description': description,
      };

  factory DoorbellEvent.fromJson(Map<String, dynamic> json) => DoorbellEvent(
        id: json['id'] as String,
        type: json['type'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        mediaUrl: json['mediaUrl'] as String?,
        description: json['description'] as String?,
      );
}

class AccessUser {
  final String id;
  final String name;
  final String role; // 'admin', 'guest', 'restricted'
  final bool canUnlock;
  final DateTime? accessUntil;

  AccessUser({
    required this.id,
    required this.name,
    required this.role,
    required this.canUnlock,
    this.accessUntil,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'canUnlock': canUnlock,
        'accessUntil': accessUntil?.toIso8601String(),
      };

  factory AccessUser.fromJson(Map<String, dynamic> json) => AccessUser(
        id: json['id'] as String,
        name: json['name'] as String,
        role: json['role'] as String,
        canUnlock: json['canUnlock'] as bool,
        accessUntil: json['accessUntil'] != null
            ? DateTime.parse(json['accessUntil'] as String)
            : null,
      );
}

// ✅ Audio message model
class AudioMessage {
  final String id;
  final String title;
  final String file;
  final bool enabled;

  AudioMessage({
    required this.id,
    required this.title,
    required this.file,
    required this.enabled,
  });

  factory AudioMessage.fromMap(String id, Map m) {
    return AudioMessage(
      id: id,
      title: (m['title'] ?? id).toString(),
      file: (m['file'] ?? "").toString(),
      enabled: (m['enabled'] ?? true) == true,
    );
  }
}

class DoorbellService {
  // ============================
  // Local storage (SharedPrefs)
  // ============================
  static const _keyEvents = 'doorbell_events';
  static const _keyAccessUsers = 'doorbell_access_users';

  static SharedPreferences? _prefs;

  static List<DoorbellEvent> _events = [];
  static List<AccessUser> _accessUsers = [
    AccessUser(
      id: '1',
      name: 'You (Homeowner)',
      role: 'admin',
      canUnlock: true,
    ),
  ];

  /// Call once in main() before using the service.
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();

    // Load events
    final eventsJson = _prefs!.getString(_keyEvents);
    if (eventsJson != null) {
      final List list = jsonDecode(eventsJson) as List;
      _events = list
          .map((e) => DoorbellEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // Load access users
    final usersJson = _prefs!.getString(_keyAccessUsers);
    if (usersJson != null) {
      final List list = jsonDecode(usersJson) as List;
      _accessUsers = list
          .map((e) => AccessUser.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      // first run: save default users
      await _saveAccessUsers();
    }
  }

  static Future<void> _saveEvents() async {
    if (_prefs == null) return;
    final list = _events.map((e) => e.toJson()).toList();
    await _prefs!.setString(_keyEvents, jsonEncode(list));
  }

  static Future<void> _saveAccessUsers() async {
    if (_prefs == null) return;
    final list = _accessUsers.map((u) => u.toJson()).toList();
    await _prefs!.setString(_keyAccessUsers, jsonEncode(list));
  }

  // ============================
  // API used by UI (local)
  // ============================
  List<DoorbellEvent> getEventHistory() => List.unmodifiable(_events);

  void addEvent(DoorbellEvent event) {
    _events.insert(0, event);
    _saveEvents();
  }

  List<AccessUser> getAccessUsers() => List.unmodifiable(_accessUsers);

  void addAccessUser(AccessUser user) {
    _accessUsers.add(user);
    _saveAccessUsers();
  }

  void removeAccessUser(String id) {
    _accessUsers.removeWhere((u) => u.id == id);
    _saveAccessUsers();
  }

  Future<bool> remoteUnlock() async {
    await Future.delayed(const Duration(seconds: 1));
    addEvent(DoorbellEvent(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: 'unlock',
      timestamp: DateTime.now(),
      description: 'Door unlocked remotely',
    ));
    return true;
  }

  String generateOneTimeCode() {
    return '${(DateTime.now().hour).toString().padLeft(2, '0')}'
        '${(DateTime.now().minute).toString().padLeft(2, '0')}'
        '${(100 + DateTime.now().second).toString()}';
  }

  // ============================
  // Firebase helpers (LIVE + CAM + AUDIO)
  // ============================
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // --- Live controls ---
  Future<void> setLiveActive(bool active) async {
    try {
      await _db.child('live/active').set(active);
    } catch (_) {}
  }

  Future<void> setLiveFps(int fps) async {
    final safe = fps.clamp(1, 5);
    try {
      await _db.child('live/fps').set(safe);
    } catch (_) {}
  }

  // --- ✅ Camera settings (used by LiveViewTab) ---
  Future<void> applyCameraSettings(Map<String, dynamic> patch) async {
    final Map<String, dynamic> safe = {};

    int clampInt(dynamic v, int min, int max, int fallback) {
      final parsed = v is int ? v : int.tryParse(v?.toString() ?? '');
      return (parsed ?? fallback).clamp(min, max);
    }

    if (patch.containsKey('vflip')) safe['vflip'] = patch['vflip'] == true;
    if (patch.containsKey('hmirror')) safe['hmirror'] = patch['hmirror'] == true;

    if (patch.containsKey('brightness')) {
      safe['brightness'] = clampInt(patch['brightness'], -2, 2, 0);
    }
    if (patch.containsKey('contrast')) {
      safe['contrast'] = clampInt(patch['contrast'], -2, 2, 0);
    }
    if (patch.containsKey('saturation')) {
      safe['saturation'] = clampInt(patch['saturation'], -2, 2, 0);
    }
    if (patch.containsKey('quality')) {
      safe['quality'] = clampInt(patch['quality'], 10, 63, 10);
    }

    if (patch.containsKey('flash')) safe['flash'] = patch['flash'] == true;

    // ✅ framesize (int enum)
    if (patch.containsKey('framesize')) {
      final fs = (patch['framesize'] is int)
          ? patch['framesize'] as int
          : int.tryParse(patch['framesize']?.toString() ?? '');
      const allowed = {3, 6, 8, 10, 12}; // QQVGA,QVGA,VGA,SVGA,XGA
      if (fs != null && allowed.contains(fs)) {
        safe['framesize'] = fs;
      }
    }

    try {
      await _db.child('camera/settings').update(safe);
      await _db.child('camera/apply_seq').set(DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> setLanPreferred(bool isNearLan) async {
    try {
      await _db.child('camera/client_near_lan').set(isNearLan);
    } catch (_) {}
  }

  Future<void> publishCameraIp(String ip) async {
    try {
      await _db.child('camera/ip').set(ip);
    } catch (_) {}
  }

  // ==========================================================
  // ✅ Pre-recorded audio (MATCHES your Firebase structure)
  // Firebase:
  //   /audio/active  (bool)
  //   /audio/command (string): NONE | STOP | <messageKey>
  //   /audio/messages/<key>/{enabled,title,file}
  // ==========================================================

  Future<void> setAudioActive(bool active) async {
    try {
      await _db.child('audio/active').set(active);
    } catch (_) {}
  }

  Stream<bool> watchAudioActive() {
    return _db.child('audio/active').onValue.map((event) {
      return event.snapshot.value == true;
    });
  }

  Stream<String> watchAudioCommand() {
    return _db.child('audio/command').onValue.map((event) {
      return (event.snapshot.value ?? "NONE").toString();
    });
  }

  Stream<List<AudioMessage>> watchAudioMessages() {
    return _db.child('audio/messages').onValue.map((event) {
      final v = event.snapshot.value;
      if (v == null || v is! Map) return <AudioMessage>[];

      final list = <AudioMessage>[];
      v.forEach((key, value) {
        if (value is Map) {
          list.add(AudioMessage.fromMap(key.toString(), value));
        }
      });
      list.sort((a, b) => a.title.compareTo(b.title));
      return list;
    });
  }

  Future<void> sendAudioCommand(String cmd) async {
    try {
      await _db.child('audio/command').set(cmd);
    } catch (_) {}
  }

  Future<void> stopAudio() async {
    await sendAudioCommand("STOP");
  }

  Future<bool> playMessage(String msgId) async {
    // Optional: block if disabled
    try {
      final enabledSnap = await _db.child('audio/messages/$msgId/enabled').get();
      if (enabledSnap.value == false) {
        throw Exception("Message '$msgId' is disabled in Firebase");
      }
    } catch (_) {
      // If missing node/field, still try to play
    }

    // Ensure audio polling is on (Remote tab sets it too)
    await setAudioActive(true);

    // Command = message key (ESP32 reads /audio/messages/<key>/file)
    await sendAudioCommand(msgId);

    // Local history event
    addEvent(DoorbellEvent(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: 'message',
      timestamp: DateTime.now(),
      description: 'Play pre-recorded message: $msgId',
    ));

    return true;
  }
}
