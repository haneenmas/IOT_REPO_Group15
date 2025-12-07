import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_app/services/doorbell_service.dart';
import '../../../services/visitor_service.dart';
import 'package:intl/intl.dart';


class OneTimeCodesPage extends StatefulWidget {
  const OneTimeCodesPage({super.key, required DoorbellService doorbellService});
  
  @override
  State<OneTimeCodesPage> createState() => _OneTimeCodesPageState();
}

class _OneTimeCodesPageState extends State<OneTimeCodesPage> {
  final _nameCtrl = TextEditingController();
  int _validHours = 24;
  final _svc = VisitorService();

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _copyToClipboard(String text, {String? label}) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label ?? 'Copied to clipboard')));
  }

  void _generate() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter visitor name')));
      return;
    }
    final visitor = _svc.addVisitor(name, validHours: _validHours);
    _nameCtrl.clear();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('One-Time Code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Name: ${visitor.name}'),
            const SizedBox(height: 8),
            SelectableText(
              'Code: ${visitor.code}',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Valid Until: ${visitor.validUntil != null ? DateFormat.yMd().add_jm().format(visitor.validUntil!) : '-'}'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          TextButton(
            onPressed: () {
              _copyToClipboard(visitor.code, label: 'Code copied');
              Navigator.pop(context);
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    setState(() {});
  }

  Future<void> _simulateEntryDialog() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Simulate Keypad Entry'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Enter code')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final code = ctrl.text.trim();
              Navigator.pop(context);
              if (code.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a code to simulate')));
                return;
              }
              _simulateVerify(code);
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    ctrl.dispose();
  }

  void _simulateVerify(String code) {
    final res = _svc.verifyCode(code);
    // verifyCode returns Map<String, dynamic> with keys: 'success', 'message', optionally 'visitor'
    String message = 'Invalid or expired code';
    final success = res['success'];
    if (success == true) {
      final visitor = res['visitor'];
      if (visitor is Visitor) {
        message = 'Code accepted for ${visitor.name} — door unlocked (simulated)';
      } else {
        message = 'Code accepted — door unlocked (simulated)';
      }
    } else {
      message = res['message']?.toString() ?? 'Invalid or expired code';
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final active = _svc.getActiveVisitors();
    final history = _svc.getVisitHistory();
    return Scaffold(
      appBar: AppBar(title: const Text('One-Time Access Codes')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Create One-Time Code', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Visitor name', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Valid for:'),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: _validHours,
              onChanged: (v) => setState(() => _validHours = v ?? 24),
              items: [1, 3, 6, 12, 24, 48].map((h) => DropdownMenuItem(value: h, child: Text('$h hours'))).toList(),
            ),
            const Spacer(),
            ElevatedButton(onPressed: _generate, child: const Text('Generate')),
          ]),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _simulateEntryDialog,
            icon: const Icon(Icons.phonelink_lock),
            label: const Text('Simulate Keypad Entry'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
          ),
          const SizedBox(height: 24),
          const Text('Active Codes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (active.isEmpty) const Text('No active one-time codes'),
          ...active.map((v) => Card(
            child: ListTile(
              title: Text('${v.name} — ${v.code}'),
              subtitle: Text('Valid until: ${v.validUntil != null ? DateFormat.yMd().add_jm().format(v.validUntil!) : '-'}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy code',
                  onPressed: () => _copyToClipboard(v.code),
                ),
                IconButton(
                  icon: const Icon(Icons.login),
                  tooltip: 'Simulate verify',
                  onPressed: () => _simulateVerify(v.code),
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () { _svc.deleteVisitor(v.id); setState(() {}); },
                ),
              ]),
            ),
          )),
          const SizedBox(height: 24),
          const Text('Visit History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (history.isEmpty) const Text('No visits yet'),
          ...history.map((v) => Card(
            child: ListTile(
              leading: Icon(v.isUsed ? Icons.check_circle : Icons.schedule, color: v.isUsed ? Colors.green : Colors.orange),
              title: Text('${v.name} — ${v.code}'),
              subtitle: Text(v.isUsed ? 'Used at ${v.usedAt != null ? DateFormat.yMd().add_jm().format(v.usedAt!) : '-'}' : 'Not used'),
              trailing: v.isUsed ? null : IconButton(icon: const Icon(Icons.delete), onPressed: () { _svc.deleteVisitor(v.id); setState(() {}); }),
            ),
          )),
        ]),
      ),
    );
  }
}
