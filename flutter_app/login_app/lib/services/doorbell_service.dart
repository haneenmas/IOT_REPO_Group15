import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class DoorbellEvent {
  final String id;
  final String type; // 'snapshot', 'motion', 'unlock', 'failed_code'
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

class DoorbellService {
  static const _keyEvents = 'doorbell_events';
  static const _keyAccessUsers = 'doorbell_access_users';

  static SharedPreferences? _prefs;

  static List<DoorbellEvent> _events = [
    // you can keep some initial fake events if you want
  ];

  static List<AccessUser> _accessUsers = [
    AccessUser(
      id: '1',
      name: 'You (Homeowner)',
      role: 'admin',
      canUnlock: true,
    ),
    AccessUser(
      id: '2',
      name: 'John Doe',
      role: 'guest',
      canUnlock: false,
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

  // ===== API used by UI =====

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
    return '${(DateTime.now().hour).toString().padLeft(2, '0')}${(DateTime.now().minute).toString().padLeft(2, '0')}${(100 + DateTime.now().second).toString()}';
  }

  Future<bool> playMessage(String messageId) async {
    await Future.delayed(const Duration(seconds: 1));
    addEvent(DoorbellEvent(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: 'message',
      timestamp: DateTime.now(),
      description: 'Pre-recorded message played',
    ));
    return true;
  }
}
