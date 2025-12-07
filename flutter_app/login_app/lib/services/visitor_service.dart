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
}

class VisitorService {
  static final List<Visitor> _visitors = [];

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

    if (visitor == null) return {'success': false, 'message': 'Code not found'};
    if (visitor.isUsed) return {'success': false, 'message': 'Code already used'};
    if (visitor.validUntil != null && DateTime.now().isAfter(visitor.validUntil!)) {
      return {'success': false, 'message': 'Code expired'};
    }

    visitor.isUsed = true;
    visitor.usedAt = DateTime.now();
    return {'success': true, 'message': 'Access granted!', 'visitor': visitor};
  }

  List<Visitor> getVisitHistory() => List.unmodifiable(_visitors);

  List<Visitor> getActiveVisitors() {
    final now = DateTime.now();
    return _visitors.where((v) => !v.isUsed && (v.validUntil == null || now.isBefore(v.validUntil!))).toList();
  }

  void deleteVisitor(String id) => _visitors.removeWhere((v) => v.id == id);
}
