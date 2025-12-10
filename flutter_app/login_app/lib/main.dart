import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart'; // Add this
import 'firebase_options.dart'; // Add this
import 'screens/auth/login_page.dart';
import 'screens/dashboard/dashboard_page.dart';
import 'services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. INITIALIZE FIREBASE (Crucial!)
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 2. Initialize Auth (Keep this for login)
  await AuthService.init();

  runApp(const SmartDoorbellApp());
}

class SmartDoorbellApp extends StatelessWidget {
  const SmartDoorbellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Doorbell',
      debugShowCheckedModeBanner: false,
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