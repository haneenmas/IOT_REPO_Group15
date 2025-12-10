import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database/ui/firebase_animated_list.dart';
import 'package:flutter/material.dart';
import '../../../services/doorbell_service.dart';
import 'one_time_codes_page.dart';

class AccessTab extends StatefulWidget {
  final DoorbellService doorbellService; // Keep for compatibility
  const AccessTab({super.key, required this.doorbellService});

  @override
  State<AccessTab> createState() => _AccessTabState();
}

class _AccessTabState extends State<AccessTab> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();

  // --- ADD USER DIALOG ---
  void _showAddUserDialog() {
    _nameController.clear();
    _pinController.clear();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Add New User"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: "Name (e.g. Dad)",
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pinController,
              decoration: const InputDecoration(
                labelText: "4-Digit PIN",
                prefixIcon: Icon(Icons.lock),
              ),
              keyboardType: TextInputType.number,
              maxLength: 4,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () async {
              if (_nameController.text.isNotEmpty &&
                  _pinController.text.length == 4) {
                // Save to Firebase: /access_codes/1234 -> "Dad"
                await _dbRef
                    .child('access_codes')
                    .child(_pinController.text)
                    .set(_nameController.text);
                if (mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${_nameController.text} added!')),
                  );
                }
              }
            },
            child: const Text("Add User"),
          ),
        ],
      ),
    );
  }

  // --- DELETE USER ---
  void _deleteUser(String pin, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete User?"),
        content: Text("Are you sure you want to remove $name?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(
            onPressed: () {
              _dbRef.child('access_codes').child(pin).remove();
              Navigator.pop(ctx);
            },
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Access Users", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),

            Expanded(
              child: FirebaseAnimatedList(
                query: _dbRef.child('access_codes'),
                defaultChild: const Center(child: CircularProgressIndicator()),
                itemBuilder: (context, snapshot, animation, index) {
                  final name = snapshot.value.toString();
                  final pin = snapshot.key.toString();

                  // Hide "OTP_Visitor" from this list
                  if (name == "OTP_Visitor") return const SizedBox.shrink();

                  return SizeTransition(
                    sizeFactor: animation,
                    child: Card(
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(name),
                        subtitle: Text("PIN: ****${pin.substring(pin.length - 1)}"),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.grey),
                          onPressed: () => _deleteUser(pin, name),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _showAddUserDialog,
                icon: const Icon(Icons.person_add),
                label: const Text("Add User"),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => OneTimeCodesPage(doorbellService: widget.doorbellService),
                    ),
                  );
                },
                icon: const Icon(Icons.key),
                label: const Text("Manage One-Time Codes"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}