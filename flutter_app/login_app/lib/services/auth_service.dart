import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const _prefsUsersKey = 'auth_users';

  // in-memory cache of users: email -> password
  static Map<String, String> _users = {
    'homeowner@smartdoor.com': 'password123',
    'user@example.com': 'password',
  };

  static SharedPreferences? _prefs;

  /// MUST be called once before using AuthService (we'll do it in main()).
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();

    final stored = _prefs!.getString(_prefsUsersKey);
    if (stored != null) {
      final Map<String, dynamic> decoded =
          jsonDecode(stored) as Map<String, dynamic>;
      _users = decoded.map(
        (k, v) => MapEntry(k, v as String),
      );
    } else {
      // first run: save the default users
      await _persistUsers();
    }
  }

  static Future<void> _persistUsers() async {
    if (_prefs == null) return;
    await _prefs!.setString(_prefsUsersKey, jsonEncode(_users));
  }

  Future<bool> login({
    required String email,
    required String password,
  }) async {
    await Future.delayed(const Duration(milliseconds: 600));
    return _users[email] == password;
  }

  Future<bool> signup({
    required String email,
    required String password,
    required String name,
  }) async {
    await Future.delayed(const Duration(milliseconds: 600));

    if (_users.containsKey(email)) {
      // email already used
      return false;
    }

    _users[email] = password;
    await _persistUsers();
    return true;
  }
}
