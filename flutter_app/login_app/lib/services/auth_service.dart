class AuthService {
  // Mock user database
  static const Map<String, String> _users = {
    'homeowner@smartdoor.com': 'password123',
    'user@example.com': 'password',
  };

  Future<bool> login({required String email, required String password}) async {
    await Future.delayed(const Duration(seconds: 1));
    return _users[email] == password;
  }

  Future<bool> signup({
    required String email,
    required String password,
    required String name,
  }) async {
    await Future.delayed(const Duration(seconds: 1));
    if (_users.containsKey(email)) return false;
    return true;
  }
}