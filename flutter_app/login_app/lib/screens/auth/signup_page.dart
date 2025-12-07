import 'package:flutter/material.dart';
import '../../services/auth_service.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});
  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();
  final _auth = AuthService();
  bool _loading = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final ok = await _auth.signup(email: _emailCtrl.text.trim(), password: _passCtrl.text, name: _nameCtrl.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account created! Please log in.')));
      if (!mounted) return;
      Navigator.pop(context);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email already exists')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign Up')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Full Name', prefixIcon: Icon(Icons.person), border: OutlineInputBorder()), validator: (v) => (v == null || v.isEmpty) ? 'Enter name' : null),
              const SizedBox(height: 12),
              TextFormField(controller: _emailCtrl, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email), border: OutlineInputBorder()), validator: (v) {
                if (v == null || v.isEmpty) return 'Enter email';
                if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v)) return 'Valid email required';
                return null;
              }),
              const SizedBox(height: 12),
              TextFormField(controller: _passCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock), border: OutlineInputBorder()), validator: (v) {
                if (v == null || v.isEmpty) return 'Enter password';
                if (v.length < 6) return 'At least 6 characters';
                return null;
              }),
              const SizedBox(height: 12),
              TextFormField(controller: _confirmPassCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm Password', prefixIcon: Icon(Icons.lock), border: OutlineInputBorder()), validator: (v) {
                if (v != _passCtrl.text) return 'Passwords do not match';
                return null;
              }),
              const SizedBox(height: 24),
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton(onPressed: _loading ? null : _submit, child: _loading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Sign Up'))),
            ],
          ),
        ),
      ),
    );
  }
}
