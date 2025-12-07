import 'package:flutter/material.dart';

class PinEntryScreen extends StatefulWidget {
  final Function(bool) onResult;
  const PinEntryScreen({super.key, required this.onResult});
  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  final _pinService = PinLockService();
  String _pinInput = '';
  bool _isLocked = false;
  int _remainingSeconds = 0;

  @override
  void initState() {
    super.initState();
    _checkLockStatus();
  }

  void _checkLockStatus() {
    final status = _pinService.getStatus();
    setState(() {
      _isLocked = status['isLocked'] as bool;
      _remainingSeconds = status['remainingSeconds'] as int;
    });
    if (_isLocked) {
      _startCountdown();
    }
  }

  void _startCountdown() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted && _remainingSeconds > 0) {
        setState(() => _remainingSeconds--);
        if (_remainingSeconds > 0) {
          _startCountdown();
        } else {
          setState(() => _isLocked = false);
        }
      }
    });
  }

  void _addDigit(String digit) {
    if (_isLocked) return;
    if (_pinInput.length < 4) {
      setState(() => _pinInput += digit);
    }
  }

  void _deleteLast() {
    if (_pinInput.isNotEmpty) {
      setState(() => _pinInput = _pinInput.substring(0, _pinInput.length - 1));
    }
  }

  void _submit() {
    if (_isLocked || _pinInput.length != 4) return;
    final result = _pinService.verifyPin(_pinInput);
    if (result['success']) {
      widget.onResult(true);
      Navigator.pop(context);
    } else {
      setState(() => _pinInput = '');
      final failureCount = result['failureCount'] as int;
      final message = result['message'] as String;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red));
      if (failureCount >= 5) {
        _checkLockStatus();
      }
    }
  }

  Widget _buildPinDot(int index) {
    return Container(width: 20, height: 20, margin: const EdgeInsets.all(8), decoration: BoxDecoration(shape: BoxShape.circle, color: index < _pinInput.length ? Colors.blue : Colors.grey.shade300));
  }

  Widget _buildButton(String label, VoidCallback onPressed) {
    return ElevatedButton(onPressed: _isLocked ? null : onPressed, child: Text(label, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Door PIN Entry')),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isLocked)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    children: [
                      const Icon(Icons.lock, size: 48, color: Colors.red),
                      const SizedBox(height: 12),
                      const Text('Too many failed attempts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red)),
                      const SizedBox(height: 8),
                      Text('Try again in $_remainingSeconds seconds', style: const TextStyle(fontSize: 14, color: Colors.red)),
                    ],
                  ),
                )
              else
                Column(
                  children: [
                    const Text('Enter 4-Digit PIN', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 24),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(4, (i) => _buildPinDot(i))),
                    const SizedBox(height: 32),
                    Column(
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: ['1', '2', '3'].map((d) => SizedBox(width: 80, height: 60, child: _buildButton(d, () => _addDigit(d)))).toList()),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: ['4', '5', '6'].map((d) => SizedBox(width: 80, height: 60, child: _buildButton(d, () => _addDigit(d)))).toList()),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: ['7', '8', '9'].map((d) => SizedBox(width: 80, height: 60, child: _buildButton(d, () => _addDigit(d)))).toList()),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          SizedBox(width: 80, height: 60, child: ElevatedButton(onPressed: _pinInput.isEmpty ? null : _deleteLast, child: const Icon(Icons.backspace, size: 24))),
                          const SizedBox(width: 12),
                          SizedBox(width: 80, height: 60, child: _buildButton('0', () => _addDigit('0'))),
                          const SizedBox(width: 12),
                          SizedBox(width: 80, height: 60, child: ElevatedButton(onPressed: _pinInput.length == 4 ? _submit : null, style: ElevatedButton.styleFrom(backgroundColor: Colors.green), child: const Icon(Icons.check, size: 24, color: Colors.white))),
                        ]),
                      ],
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class PinLockService {
  static int _failureCount = 0;
  static DateTime? _lockUntil;
  static const String _correctPin = '1234';
  static const int _maxFailures = 5;
  static const int _lockoutSeconds = 120;

  Map<String, dynamic> verifyPin(String pin) {
    if (_isLocked()) {
      return {'success': false, 'failureCount': _failureCount, 'message': 'Too many failed attempts. Try again later.'};
    }

    if (pin == _correctPin) {
      _failureCount = 0;
      _lockUntil = null;
      return {'success': true, 'failureCount': 0, 'message': 'PIN correct!'};
    }

    _failureCount++;
    if (_failureCount >= _maxFailures) {
      _lockUntil = DateTime.now().add(const Duration(seconds: _lockoutSeconds));
      return {'success': false, 'failureCount': _failureCount, 'message': 'Locked for 2 minutes after 5 failed attempts.'};
    }

    return {'success': false, 'failureCount': _failureCount, 'message': 'Incorrect PIN. Attempts remaining: ${_maxFailures - _failureCount}'};
  }

  Map<String, dynamic> getStatus() {
    final locked = _isLocked();
    final remaining = locked ? _lockUntil!.difference(DateTime.now()).inSeconds : 0;
    return {'isLocked': locked, 'remainingSeconds': remaining, 'failureCount': _failureCount};
  }

  bool _isLocked() {
    if (_lockUntil == null) return false;
    if (DateTime.now().isAfter(_lockUntil!)) {
      _lockUntil = null;
      _failureCount = 0;
      return false;
    }
    return true;
  }

  void reset() {
    _failureCount = 0;
    _lockUntil = null;
  }
}
