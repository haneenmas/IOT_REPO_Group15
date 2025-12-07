import 'package:flutter/material.dart';
import '../../../services/doorbell_service.dart';
import 'one_time_codes_page.dart';

class AccessTab extends StatefulWidget {
  final DoorbellService doorbellService;

  const AccessTab({
    super.key,
    required this.doorbellService,
  });

  @override
  State<AccessTab> createState() => _AccessTabState();
}

class _AccessTabState extends State<AccessTab> {
  late List<AccessUser> _users;

  @override
  void initState() {
    super.initState();
    _users = widget.doorbellService.getAccessUsers();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Access Users',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ..._users.map((user) => _buildUserCard(user)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _showAddUserDialog,
              icon: const Icon(Icons.person_add),
              label: const Text('Add User'),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OneTimeCodesPage(
                      doorbellService: widget.doorbellService, // ✅ pass it
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.vpn_key),
              label: const Text('Manage One-Time Codes'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard(AccessUser user) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.person),
        title: Text(user.name),
        subtitle: Text(user.role),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (user.canUnlock) const Icon(Icons.lock_open, color: Colors.green),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${user.name} removed')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddUserDialog() {
    final nameCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add User'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(hintText: 'User name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty) {
                final newUser = AccessUser(
                  id: DateTime.now().toString(),
                  name: nameCtrl.text,
                  role: 'guest',
                  canUnlock: false,
                );
                widget.doorbellService.addAccessUser(newUser);
                setState(() {
                  _users = widget.doorbellService.getAccessUsers();
                });
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${nameCtrl.text} added!')),
                );
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
