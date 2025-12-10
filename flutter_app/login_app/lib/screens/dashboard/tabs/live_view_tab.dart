import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../../services/doorbell_service.dart';

class LiveViewTab extends StatefulWidget {
  final DoorbellService doorbellService;
  const LiveViewTab({super.key, required this.doorbellService});

  @override
  State<LiveViewTab> createState() => _LiveViewTabState();
}

class _LiveViewTabState extends State<LiveViewTab> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  
  // We start with an empty URL until Firebase gives us the real one
  String _streamUrl = "";
  String _cameraIp = "Loading...";

  @override
  void initState() {
    super.initState();
    _setupListeners();
  }

  void _setupListeners() {
    // 1. LISTEN FOR CAMERA IP UPDATES
    // The Camera uploads its IP to "/camera_ip"
    _dbRef.child('camera_ip').onValue.listen((event) {
      final val = event.snapshot.value;
      if (val != null) {
        setState(() {
          _cameraIp = val.toString();
          // Construct the full URL: http://[IP]:81/stream
          _streamUrl = 'http://$_cameraIp:81/stream';
        });
        print("New Camera IP received: $_cameraIp");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 1. DOOR STATUS CARD
          StreamBuilder(
            stream: _dbRef.child('door_status').onValue,
            builder: (context, snapshot) {
              String status = "Unknown";
              if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                status = snapshot.data!.snapshot.value.toString();
              }
              bool isOpen = (status == "Open");
              
              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isOpen ? Colors.green.shade100 : Colors.red.shade100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isOpen ? Colors.green : Colors.red),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(isOpen ? Icons.lock_open : Icons.lock, color: isOpen ? Colors.green : Colors.red),
                    const SizedBox(width: 10),
                    Text(
                      "Door is $status", 
                      style: TextStyle(fontWeight: FontWeight.bold, color: isOpen ? Colors.green.shade900 : Colors.red.shade900)
                    ),
                  ],
                ),
              );
            },
          ),

          // 2. LIVE VIDEO BOX (Dynamic!)
          Container(
            height: 300,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _streamUrl.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 10),
                          Text("Fetching Camera IP...", style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    )
                  : Mjpeg(
                      isLive: true,
                      stream: _streamUrl,
                      // Increase timeout for slow networks
                      timeout: const Duration(seconds: 20), 
                      loading: (context) => Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(color: Colors.white),
                            const SizedBox(height: 10),
                            Text("Connecting to $_cameraIp...", 
                                style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                      error: (context, error, stack) => Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.videocam_off, color: Colors.white54, size: 48),
                            const Text("Stream Offline", style: TextStyle(color: Colors.white54)),
                            Text("IP: $_cameraIp", style: const TextStyle(color: Colors.white24, fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          
          const SizedBox(height: 10),
          Text("Camera IP: $_cameraIp", style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 24),

          // 3. CONTROLS
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Snapshot feature coming soon!'))
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