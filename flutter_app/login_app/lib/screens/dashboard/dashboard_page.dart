import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../services/doorbell_service.dart';
import 'tabs/live_view_tab.dart';
import 'tabs/history_tab.dart';
import 'tabs/access_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/one_time_codes_page.dart';
import 'tabs/door_audio_screen.dart';
import 'tabs/remote_control_tab.dart';
import 'tabs/notifications_tab.dart';

class DashboardPage extends StatefulWidget {
  final Function() onLogout;

  const DashboardPage({
    super.key,
    required this.onLogout,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;

  final DoorbellService _doorbellService = DoorbellService();
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  static const int _liveTabIndex = 0;

  // ✅ Refresh keys for Android stability
  int _notifRefresh = 0;
  int _histRefresh = 0;
  int _accessRefresh = 0;
  int _otpRefresh = 0;

  Future<void> _setLiveActive(bool active) async {
    try {
      await _db.child('live/active').set(active);
    } catch (e) {
      debugPrint('Failed to set live/active: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    FirebaseDatabase.instance.goOnline();
    _setLiveActive(_selectedIndex == _liveTabIndex);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setLiveActive(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      _setLiveActive(false);
    } else if (state == AppLifecycleState.resumed) {
      FirebaseDatabase.instance.goOnline();
      _setLiveActive(_selectedIndex == _liveTabIndex);
      setState(() {}); // reattach visible listeners
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      LiveViewTab(
        key: const PageStorageKey('live'),
        doorbellService: _doorbellService,
      ),
      NotificationsTab(
        key: ValueKey('notifications_$_notifRefresh'),
        doorbellService: _doorbellService,
      ),
      HistoryTab(
        key: ValueKey('history_$_histRefresh'),
        doorbellService: _doorbellService,
      ),
      AccessTab(
        key: ValueKey('access_$_accessRefresh'),
        doorbellService: _doorbellService,
      ),
      OneTimeCodesPage(
        key: ValueKey('otp_$_otpRefresh'),
        doorbellService: _doorbellService,
      ),
      RemoteControlTab(
        key: const PageStorageKey('remote'),
        doorbellService: _doorbellService,
      ),
      SettingsTab(
        key: const PageStorageKey('settings'),
        onLogout: () async {
          await _setLiveActive(false);
          widget.onLogout();
        },
        doorbellService: _doorbellService,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Doorbell'),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.hearing),
            tooltip: 'Listen to door',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const DoorAudioScreen(),
                ),
              );
            },
          ),
        ],
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
        onTap: (index) async {
          FirebaseDatabase.instance.goOnline();

          await _setLiveActive(index == _liveTabIndex);

          setState(() {
            _selectedIndex = index;

            // ✅ Refresh tabs when entering
            if (index == 1) _notifRefresh++;
            if (index == 2) _histRefresh++;
            if (index == 3) _accessRefresh++;
            if (index == 4) _otpRefresh++;
          });
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.videocam), label: 'Live View'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications), label: 'Notifications'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
          BottomNavigationBarItem(icon: Icon(Icons.lock), label: 'Access'),
          BottomNavigationBarItem(icon: Icon(Icons.vpn_key), label: 'One-Time'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_remote), label: 'Remote'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
