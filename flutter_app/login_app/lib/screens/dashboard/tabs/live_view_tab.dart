import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../../services/doorbell_service.dart';

enum ViewMode { semiLive, lan }

class LiveViewTab extends StatefulWidget {
  final DoorbellService doorbellService;
  const LiveViewTab({super.key, required this.doorbellService});

  @override
  State<LiveViewTab> createState() => _LiveViewTabState();
}

class _LiveViewTabState extends State<LiveViewTab> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  ViewMode _mode = ViewMode.semiLive;

  // We treat remote updates as 1fps (every 1 second) as you requested.
  static const int _fixedRemoteFps = 1;

  // ✅ LAN data from Firebase (/lan/...)
  String _lanStreamUrl = "";
  String _lanIp = "";
  bool _lanOnline = false;

  // Camera settings (safe subset)
  bool _vflip = true;
  bool _hmirror = false;
  int _brightness = 0; // -2..2
  int _contrast = 0; // -2..2
  int _saturation = 0; // -2..2
  int _quality = 10; // 10..63
  bool _flash = false;

  // framesize enum (QQVGA=3, QVGA=6, VGA=8, SVGA=10, XGA=12)
  int _framesize = 6;

  // -------------------------
  // ✅ Live frame cache (avoid black flicker)
  // -------------------------
  Uint8List? _lastLiveBytes;
  dynamic _lastLiveTs;
  DateTime? _lastLiveRxAt;

  // If no updates, we first show a "Reconnecting..." overlay,
  // then after longer time we clear the image (so it won't show forever).
  static const Duration _warnStaleAfter = Duration(seconds: 3);
  static const Duration _clearAfter = Duration(seconds: 12);

  Timer? _staleTimer;

  // keep subscriptions so we can cancel
  StreamSubscription<DatabaseEvent>? _lanUrlSub;
  StreamSubscription<DatabaseEvent>? _lanIpSub;
  StreamSubscription<DatabaseEvent>? _lanOnlineSub;
  StreamSubscription<DatabaseEvent>? _camSettingsSub;

  // ✅ Instead of StreamBuilder decoding in build (heavy),
  // we listen once and update cached bytes.
  StreamSubscription<DatabaseEvent>? _liveLatestSub;

  @override
  void initState() {
    super.initState();
    _setupListeners();
    _loadInitialValues();

    // ✅ Start live automatically when opening Live tab (Remote mode)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (_mode == ViewMode.semiLive) {
        await widget.doorbellService.setLiveActive(true);
        await widget.doorbellService.setLiveFps(_fixedRemoteFps);
      }
    });

    // ✅ Periodically check staleness (so UI updates even without new frames)
    _staleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {}); // just to refresh stale overlay / clearing logic
      _maybeClearIfTooStale();
    });
  }

  @override
  void dispose() {
    // ✅ Stop firebase live when leaving the tab
    widget.doorbellService.setLiveActive(false);

    _staleTimer?.cancel();

    _lanUrlSub?.cancel();
    _lanIpSub?.cancel();
    _lanOnlineSub?.cancel();
    _camSettingsSub?.cancel();
    _liveLatestSub?.cancel();

    // ✅ Clear frame on exit so it doesn't stick around
    _clearLiveFrame();

    super.dispose();
  }

  void _clearLiveFrame() {
    _lastLiveBytes = null;
    _lastLiveTs = null;
    _lastLiveRxAt = null;
  }

  Duration? get _sinceLastFrame {
    if (_lastLiveRxAt == null) return null;
    return DateTime.now().difference(_lastLiveRxAt!);
  }

  bool get _isStaleWarning {
    final d = _sinceLastFrame;
    if (d == null) return false;
    return d >= _warnStaleAfter;
  }

  bool get _isStaleClear {
    final d = _sinceLastFrame;
    if (d == null) return false;
    return d >= _clearAfter;
  }

  void _maybeClearIfTooStale() {
    // If we haven't received anything for a long time, stop showing old picture.
    if (_isStaleClear && _lastLiveBytes != null) {
      setState(() {
        _clearLiveFrame();
      });
    }
  }

  void _setupListeners() {
    // ✅ LAN
    _lanUrlSub = _dbRef.child('lan/stream_url').onValue.listen((event) {
      final val = event.snapshot.value;
      if (!mounted) return;
      setState(() => _lanStreamUrl = (val ?? '').toString());
    });

    _lanIpSub = _dbRef.child('lan/ip').onValue.listen((event) {
      final val = event.snapshot.value;
      if (!mounted) return;
      setState(() => _lanIp = (val ?? '').toString());
    });

    _lanOnlineSub = _dbRef.child('lan/online').onValue.listen((event) {
      final val = event.snapshot.value;
      if (!mounted) return;
      setState(() => _lanOnline = val == true);
    });

    // ✅ Camera settings
    _camSettingsSub = _dbRef.child('camera/settings').onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is Map && mounted) {
        final mapped = raw.map((k, v) => MapEntry(k.toString(), v));
        setState(() {
          _vflip = (mapped['vflip'] ?? _vflip) == true;
          _hmirror = (mapped['hmirror'] ?? _hmirror) == true;
          _brightness = int.tryParse('${mapped['brightness'] ?? _brightness}') ?? _brightness;
          _contrast = int.tryParse('${mapped['contrast'] ?? _contrast}') ?? _contrast;
          _saturation = int.tryParse('${mapped['saturation'] ?? _saturation}') ?? _saturation;
          _quality = int.tryParse('${mapped['quality'] ?? _quality}') ?? _quality;
          _flash = (mapped['flash'] ?? _flash) == true;

          final fs = int.tryParse('${mapped['framesize'] ?? _framesize}') ?? _framesize;
          const allowed = {3, 6, 8, 10, 12};
          if (allowed.contains(fs)) _framesize = fs;
        });
      }
    });

    // ✅ Live latest listener (decodes once here, not inside build)
    _liveLatestSub = _dbRef.child('live/latest').onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return;

      final Map<String, dynamic> val =
          raw.map((k, v) => MapEntry(k.toString(), v));

      final imgB64 = (val['image'] ?? '').toString();
      final ts = val['ts'];

      if (imgB64.trim().isEmpty) return;

      try {
        final cleaned = _cleanBase64(imgB64);
        final bytes = base64Decode(cleaned);

        if (!mounted) return;
        setState(() {
          _lastLiveBytes = bytes;
          _lastLiveTs = ts;
          _lastLiveRxAt = DateTime.now();
        });
      } catch (_) {
        // If decode fails, DON'T wipe the last frame (avoid black flicker).
        // We just ignore this bad frame.
      }
    });
  }

  Future<void> _loadInitialValues() async {
    final lanUrlSnap = await _dbRef.child('lan/stream_url').get();
    if (lanUrlSnap.value != null && mounted) setState(() => _lanStreamUrl = lanUrlSnap.value.toString());

    final lanIpSnap = await _dbRef.child('lan/ip').get();
    if (lanIpSnap.value != null && mounted) setState(() => _lanIp = lanIpSnap.value.toString());

    final lanOnlineSnap = await _dbRef.child('lan/online').get();
    if (mounted) setState(() => _lanOnline = lanOnlineSnap.value == true);
  }

  String _cleanBase64(String s) {
    // remove whitespace/newlines
    String x = s.replaceAll(RegExp(r'\s+'), '');

    // if accidentally sent as "data:image/jpeg;base64,...."
    final idx = x.indexOf(',');
    if (x.startsWith('data:') && idx != -1) {
      x = x.substring(idx + 1);
    }
    return x;
  }

  String _formatTs(dynamic ts) {
    final int? raw = ts is int ? ts : int.tryParse(ts?.toString() ?? '');
    if (raw == null) return "Unknown time";

    final int ms = (raw < 2000000000) ? raw * 1000 : raw;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return "${dt.hour.toString().padLeft(2, '0')}:"
        "${dt.minute.toString().padLeft(2, '0')}:"
        "${dt.second.toString().padLeft(2, '0')}";
  }

  String get _effectiveLanUrl {
    if (_lanStreamUrl.trim().isNotEmpty) return _lanStreamUrl.trim();
    if (_lanIp.trim().isNotEmpty) return "http://${_lanIp.trim()}:81/stream";
    return "";
  }

  Future<void> _applyCameraSettings() async {
    await widget.doorbellService.applyCameraSettings({
      'vflip': _vflip,
      'hmirror': _hmirror,
      'brightness': _brightness.clamp(-2, 2),
      'contrast': _contrast.clamp(-2, 2),
      'saturation': _saturation.clamp(-2, 2),
      'quality': _quality.clamp(10, 63),
      'flash': _flash,
      'framesize': _framesize,
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ Camera settings applied')),
    );
  }

  Widget _doorStatusCard() {
    return StreamBuilder<DatabaseEvent>(
      stream: _dbRef.child('door_status').onValue,
      builder: (context, snapshot) {
        String status = "Unknown";
        if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
          status = snapshot.data!.snapshot.value.toString();
        }
        final isOpen = (status == "Open");

        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isOpen ? Colors.green.shade100 : Colors.red.shade100,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: isOpen ? Colors.green : Colors.red),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isOpen ? Icons.lock_open : Icons.lock,
                  color: isOpen ? Colors.green : Colors.red),
              const SizedBox(width: 10),
              Text(
                "Door is $status",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isOpen ? Colors.green.shade900 : Colors.red.shade900,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ✅ Big view helper
  Widget _bigFrame({required Widget child}) {
    return LayoutBuilder(
      builder: (context, c) {
        final double maxW = c.maxWidth;
        final double h = (maxW * 9 / 16).clamp(240.0, 520.0);
        return Container(
          height: h,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.grey.shade300),
            boxShadow: const [
              BoxShadow(
                blurRadius: 14,
                offset: Offset(0, 6),
                color: Color(0x14000000),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: child,
          ),
        );
      },
    );
  }

  // ✅ Remote live (Firebase snapshots)
  Widget _semiLiveView() {
    // If we cleared because it's too stale OR never received yet:
    if (_lastLiveBytes == null) {
      return _bigFrame(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 10),
              Text(
                "Waiting for live snapshots...",
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }

    final tsText = _formatTs(_lastLiveTs);
    final bytesLen = _lastLiveBytes!.length;

    return _bigFrame(
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.memory(
              _lastLiveBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
            ),
          ),

          // Bottom info
          Positioned(
            left: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                "Updated: $tsText • ${bytesLen}B • 1s",
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),

          // Stale overlay (short)
          if (_isStaleWarning && !_isStaleClear)
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  "Reconnecting…",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ✅ LAN view (mjpeg)
  Widget _lanView() {
    final url = _effectiveLanUrl;

    if (url.isEmpty) {
      return _bigFrame(
        child: const Center(
          child: Text(
            "LAN mode needs stream URL.\nESP should publish /lan/stream_url",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    if (!_lanOnline) {
      return _bigFrame(
        child: const Center(
          child: Text(
            "ESP is offline (LAN).\nCheck WiFi + ESP power.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    return _bigFrame(
      child: Stack(
        children: [
          Positioned.fill(
            child: Mjpeg(isLive: true, stream: url),
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                "LAN: ${_lanIp.isNotEmpty ? _lanIp : url}",
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Expanded(
            child: ChoiceChip(
              label: const Text("Remote (Firebase)"),
              selected: _mode == ViewMode.semiLive,
              onSelected: (_) async {
                setState(() {
                  _mode = ViewMode.semiLive;
                  // when switching back, start fresh (no stale old frame)
                  _clearLiveFrame();
                });
                await widget.doorbellService.setLiveActive(true);
                await widget.doorbellService.setLiveFps(_fixedRemoteFps);
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ChoiceChip(
              label: const Text("I’m near (LAN/VPN)"),
              selected: _mode == ViewMode.lan,
              onSelected: (_) async {
                setState(() {
                  _mode = ViewMode.lan;
                  // ✅ important: don't keep showing last firebase image when leaving remote mode
                  _clearLiveFrame();
                });
                await widget.doorbellService.setLiveActive(false);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ✅ Instead of FPS slider (confusing), show fixed info
  Widget _remoteRateInfo() {
    if (_mode != ViewMode.semiLive) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: const [
          Icon(Icons.speed, size: 18),
          SizedBox(width: 8),
          Text("Remote update rate: 1 frame / second"),
        ],
      ),
    );
  }

  Widget _cameraSettingsCard() {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: ExpansionTile(
        title: const Text("Camera Settings"),
        subtitle: const Text("Applies via Firebase (works anywhere)"),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Flip vertical (vflip)"),
            value: _vflip,
            onChanged: (v) => setState(() => _vflip = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Mirror (hmirror)"),
            value: _hmirror,
            onChanged: (v) => setState(() => _hmirror = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Flash on snapshot (optional)"),
            subtitle: const Text("Works only if ESP has a flash LED pin configured"),
            value: _flash,
            onChanged: (v) => setState(() => _flash = v),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text("Resolution:"),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: _framesize,
                items: const [
                  DropdownMenuItem(value: 3, child: Text("QQVGA")),
                  DropdownMenuItem(value: 6, child: Text("QVGA")),
                  DropdownMenuItem(value: 8, child: Text("VGA")),
                  DropdownMenuItem(value: 10, child: Text("SVGA")),
                  DropdownMenuItem(value: 12, child: Text("XGA")),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _framesize = v);
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          _intSlider("Brightness", _brightness, -2, 2, (v) => setState(() => _brightness = v)),
          _intSlider("Contrast", _contrast, -2, 2, (v) => setState(() => _contrast = v)),
          _intSlider("Saturation", _saturation, -2, 2, (v) => setState(() => _saturation = v)),
          _intSlider("JPEG Quality (lower=better)", _quality, 10, 63, (v) => setState(() => _quality = v)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _applyCameraSettings,
              icon: const Icon(Icons.tune),
              label: const Text("Apply Settings"),
            ),
          ),
          if (_mode == ViewMode.lan)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _effectiveLanUrl.isEmpty ? "LAN URL: (waiting...)" : "LAN stream: $_effectiveLanUrl",
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _intSlider(String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("$label: $value"),
          Slider(
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: (max - min),
            value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
            onChanged: (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _doorStatusCard(),
          _modeSelector(),
          const SizedBox(height: 12),
          (_mode == ViewMode.semiLive) ? _semiLiveView() : _lanView(),
          _remoteRateInfo(),
          _cameraSettingsCard(),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Snapshot is automatic on doorbell press ✅')),
                );
              },
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take Snapshot'),
            ),
          ),
        ],
      ),
    );
  }
}
