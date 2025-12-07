import 'package:flutter/material.dart';
import 'screens/auth/login_page.dart';
import 'screens/dashboard/dashboard_page.dart';

void main() {
  runApp(const SmartDoorbellApp());
}

class SmartDoorbellApp extends StatelessWidget {
  const SmartDoorbellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Doorbell',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isLoggedIn = false;

  void _onLoginSuccess() {
    setState(() => _isLoggedIn = true);
  }

  void _onLogout() {
    setState(() => _isLoggedIn = false);
  }

  @override
  Widget build(BuildContext context) {
    return _isLoggedIn
        ? DashboardPage(onLogout: _onLogout)
        : LoginPage(onLoginSuccess: _onLoginSuccess);
  }
}