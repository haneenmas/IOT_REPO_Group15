import 'dart:math';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database/ui/firebase_animated_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../services/doorbell_service.dart';

class OneTimeCodesPage extends StatefulWidget {
  final DoorbellService doorbellService;
  const OneTimeCodesPage({super.key, required this.doorbellService});

  @override
  State<OneTimeCodesPage> createState() => _OneTimeCodesPageState();
}

class _OneTimeCodesPageState extends State<OneTimeCodesPage> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  @override
  void initState() {
    super.initState();
    FirebaseDatabase.instance.goOnline();
  }

  Future<void> _generate() async {
    final otp = (1000 + Random().nextInt(9000)).toString();

    await _dbRef.child('access_codes').child(otp).set("OTP_Visitor");

    if (!mounted) return;

    setState(() {}); // ✅ refresh list immediately

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('One-Time Code Created'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              otp,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Valid for one use only.",
              style: TextStyle(color: Colors.grey),
            ),
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

  Future<void> _deleteCode(String code) async {
    await _dbRef.child('access_codes').child(code).remove();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final query = _dbRef.child('access_codes').orderByKey();

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
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Active Codes',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Expanded(
              child: FirebaseAnimatedList(
                query: query,
                defaultChild: const Center(child: CircularProgressIndicator()),
                itemBuilder: (context, snapshot, animation, index) {
                  final val = snapshot.value?.toString() ?? "";
                  final key = snapshot.key?.toString();

                  if (key == null) return const SizedBox.shrink();
                  if (val != "OTP_Visitor") return const SizedBox.shrink();

                  return SizeTransition(
                    sizeFactor: animation,
                    child: Card(
                      child: ListTile(
                        leading: const Icon(Icons.timer, color: Colors.orange),
                        title: Text("Code: $key"),
                        subtitle: const Text("1 Use Only"),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _deleteCode(key),
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
