import 'dart:math';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database/ui/firebase_animated_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_app/services/doorbell_service.dart';

class OneTimeCodesPage extends StatefulWidget {
  const OneTimeCodesPage({super.key, required DoorbellService doorbellService});

  @override
  State<OneTimeCodesPage> createState() => _OneTimeCodesPageState();
}

class _OneTimeCodesPageState extends State<OneTimeCodesPage> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  Future<void> _generate() async {
    String otp = (1000 + Random().nextInt(9000)).toString();
    await _dbRef.child('access_codes').child(otp).set("OTP_Visitor");

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('One-Time Code Created'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(otp, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.blue)),
            const Text("Valid for one use only.", style: TextStyle(color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: otp));
              Navigator.pop(context);
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  void _deleteCode(String code) {
    _dbRef.child('access_codes').child(code).remove();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('One-Time Access Codes')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.add_circle),
              label: const Text('Generate New Code'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
            ),
            const SizedBox(height: 20),
            const Text('Active Codes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Expanded(
              child: FirebaseAnimatedList(
                query: _dbRef.child('access_codes'),
                itemBuilder: (context, snapshot, animation, index) {
                  if (snapshot.value.toString() != "OTP_Visitor") return const SizedBox.shrink();
                  
                  return SizeTransition(
                    sizeFactor: animation,
                    child: Card(
                      child: ListTile(
                        leading: const Icon(Icons.timer, color: Colors.orange),
                        title: Text("Code: ${snapshot.key}"),
                        subtitle: const Text("1 Use Only"),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _deleteCode(snapshot.key!),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}