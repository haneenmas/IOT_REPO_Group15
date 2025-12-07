import 'package:flutter/material.dart';

class SettingsTab extends StatefulWidget {
  final Function() onLogout;

  const SettingsTab({super.key, required this.onLogout});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  int _relockTimeout = 30; // seconds
  bool _notificationsEnabled = true;
  bool _offlineMode = false;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Door Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              title: const Text('Auto-Relock Timeout'),
              subtitle:
                  Text('$_relockTimeout seconds after unlock'),
              trailing: DropdownButton(
                value: _relockTimeout,
                onChanged: (value) {
                  setState(() => _relockTimeout = value ?? 30);
                },
                items: [30, 60, 120, 300]
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text('$v seconds'),
                        ))
                    .toList(),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Notifications',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('Enable Notifications'),
              value: _notificationsEnabled,
              onChanged: (value) {
                setState(() => _notificationsEnabled = value);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(value
                          ? 'Notifications enabled'
                          : 'Notifications disabled')),
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          const Text('General',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('Offline Mode'),
              subtitle: const Text('Use local snapshots when offline'),
              value: _offlineMode,
              onChanged: (value) {
                setState(() => _offlineMode = value);
              },
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Logout'),
                    content: const Text('Are you sure?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onLogout();
                        },
                        child: const Text('Logout'),
                      ),
                    ],
                  ),
                );
              },
              icon: const Icon(Icons.logout),
              label: const Text('Logout'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}