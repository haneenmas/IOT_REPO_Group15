import 'package:flutter/material.dart';

import 'dashboard/tabs/live_view_tab.dart';
import 'dashboard/tabs/access_tab.dart';
import 'dashboard/tabs/one_time_codes_page.dart';
import 'dashboard/tabs/history_tab.dart';
import 'dashboard/tabs/settings_tab.dart';
import 'dashboard/tabs/remote_control_tab.dart'; // ✅ add this
import '../services/doorbell_service.dart';

class HomePage extends StatefulWidget {
  final DoorbellService doorbellService;
  final VoidCallback onLogout;

  const HomePage({
    super.key,
    required this.doorbellService,
    required this.onLogout,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();

    _tabs = [
      LiveViewTab(doorbellService: widget.doorbellService),
      AccessTab(doorbellService: widget.doorbellService),
      OneTimeCodesPage(doorbellService: widget.doorbellService),
      HistoryTab(doorbellService: widget.doorbellService),
      RemoteControlTab(doorbellService: widget.doorbellService), // ✅
      SettingsTab(
        doorbellService: widget.doorbellService,
        onLogout: widget.onLogout,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Doorbell')),
      body: _tabs[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.videocam), label: 'Live'),
          BottomNavigationBarItem(icon: Icon(Icons.lock), label: 'Access'),
          BottomNavigationBarItem(icon: Icon(Icons.pin), label: 'One-Time Code'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_remote), // ✅ FIX (no Icons.remote)
            label: 'Remote',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
