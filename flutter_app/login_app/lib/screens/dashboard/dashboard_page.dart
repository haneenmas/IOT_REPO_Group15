import 'package:flutter/material.dart';

import '../../services/doorbell_service.dart';
import 'tabs/live_view_tab.dart';
import 'tabs/history_tab.dart';
import 'tabs/access_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/one_time_codes_page.dart';

class DashboardPage extends StatefulWidget {
  final Function() onLogout;

  const DashboardPage({
    super.key,
    required this.onLogout,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _selectedIndex = 0;

  // Single shared instance for all tabs
  final DoorbellService _doorbellService = DoorbellService();

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      LiveViewTab(doorbellService: _doorbellService),
      HistoryTab(doorbellService: _doorbellService),
      AccessTab(doorbellService: _doorbellService),
      OneTimeCodesPage(doorbellService: _doorbellService),
      SettingsTab(
        onLogout: widget.onLogout,
        doorbellService: _doorbellService,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Doorbell'),
        centerTitle: true,
        elevation: 0,
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: tabs,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        elevation: 8,
        selectedItemColor: Theme.of(context).primaryColor,
        onTap: (index) {
          debugPrint('BottomNavigationBar tapped: $index');
          setState(() => _selectedIndex = index);
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.videocam),
            label: 'Live View',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'History',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.lock),
            label: 'Access',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.vpn_key),
            label: 'One-Time',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
