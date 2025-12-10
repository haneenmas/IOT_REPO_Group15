import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class Visitor {
  final String id;
  final String name;
  final String code;
  final DateTime createdAt;
  final DateTime? validUntil;
  bool isUsed;
  DateTime? usedAt;

  Visitor({
    required this.id,
    required this.name,
    required this.code,
    required this.createdAt,
    this.validUntil,
    this.isUsed = false,
    this.usedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'code': code,
        'createdAt': createdAt.toIso8601String(),
        'validUntil': validUntil?.toIso8601String(),
        'isUsed': isUsed,
        'usedAt': usedAt?.toIso8601String(),
      };

  factory Visitor.fromJson(Map<String, dynamic> json) => Visitor(
        id: json['id'] as String,
        name: json['name'] as String,
        code: json['code'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        validUntil: json['validUntil'] != null
            ? DateTime.parse(json['validUntil'] as String)
            : null,
        isUsed: json['isUsed'] as bool,
        usedAt: json['usedAt'] != null
            ? DateTime.parse(json['usedAt'] as String)
            : null,
      );
}

class VisitorService {
  static const _keyVisitors = 'visitors';

  static SharedPreferences? _prefs;
  static List<Visitor> _visitors = [];

  /// Call once in main().
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final visitorsJson = _prefs!.getString(_keyVisitors);
    if (visitorsJson != null) {
      final List list = jsonDecode(visitorsJson) as List;
      _visitors = list
          .map((e) => Visitor.fromJson(e as Map<String, dynamic>))
          .toList();
    }
  }

  static Future<void> _saveVisitors() async {
    if (_prefs == null) return;
    final list = _visitors.map((v) => v.toJson()).toList();
    await _prefs!.setString(_keyVisitors, jsonEncode(list));
  }

  String generateCode() {
    final rnd = DateTime.now().millisecondsSinceEpoch.remainder(9000) + 1000;
    return rnd.toString();
  }

  Visitor addVisitor(String name, {int validHours = 24}) {
    final code = generateCode();
    final visitor = Visitor(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      code: code,
      createdAt: DateTime.now(),
      validUntil: DateTime.now().add(Duration(hours: validHours)),
    );
    _visitors.insert(0, visitor);
    _saveVisitors();
    return visitor;
  }

  Map<String, dynamic> verifyCode(String code) {
    Visitor? visitor;
    for (final v in _visitors) {
      if (v.code == code) {
        visitor = v;
        break;
      }
    }

    if (visitor == null) {
      return {'success': false, 'message': 'Code not found'};
    }
    if (visitor.isUsed) {
      return {'success': false, 'message': 'Code already used'};
    }
    if (visitor.validUntil != null &&
        DateTime.now().isAfter(visitor.validUntil!)) {
      return {'success': false, 'message': 'Code expired'};
    }

    visitor.isUsed = true;
    visitor.usedAt = DateTime.now();
    _saveVisitors();

    return {
      'success': true,
      'message': 'Access granted!',
      'visitor': visitor,
    };
  }

  List<Visitor> getVisitHistory() => List.unmodifiable(_visitors);

  List<Visitor> getActiveVisitors() {
    final now = DateTime.now();
    return _visitors
        .where((v) =>
            !v.isUsed &&
            (v.validUntil == null || now.isBefore(v.validUntil!)))
        .toList();
  }

  void deleteVisitor(String id) {
    _visitors.removeWhere((v) => v.id == id);
    _saveVisitors();
  }
}
