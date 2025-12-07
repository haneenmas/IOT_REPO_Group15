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
}

class DoorbellService {
  static final List<DoorbellEvent> _events = [
    DoorbellEvent(
      id: '1',
      type: 'motion',
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      description: 'Motion detected at door',
    ),
    DoorbellEvent(
      id: '2',
      type: 'snapshot',
      timestamp: DateTime.now().subtract(const Duration(hours: 1)),
      description: 'Doorbell pressed',
    ),
  ];

  static final List<AccessUser> _accessUsers = [
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

  // Get event history
  List<DoorbellEvent> getEventHistory() => _events;

  // Add event
  void addEvent(DoorbellEvent event) => _events.insert(0, event);

  // Get access users
  List<AccessUser> getAccessUsers() => _accessUsers;

  // Add access user
  void addAccessUser(AccessUser user) => _accessUsers.add(user);

  // Remote unlock
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

  // Generate one-time code
  String generateOneTimeCode() {
    return '${(DateTime.now().hour).toString().padLeft(2, '0')}${(DateTime.now().minute).toString().padLeft(2, '0')}${(100 + DateTime.now().second).toString()}';
  }

  // Play pre-recorded message
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