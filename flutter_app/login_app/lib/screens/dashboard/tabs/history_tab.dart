import 'package:flutter/material.dart';
import '../../../services/doorbell_service.dart';

class HistoryTab extends StatelessWidget {
  final DoorbellService doorbellService;
  const HistoryTab({super.key, required this.doorbellService});
  @override
  Widget build(BuildContext context) {
    final events = doorbellService.getEventHistory();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: events.length,
      itemBuilder: (context, index) {
        final event = events[index];
        final icon = _getEventIcon(event.type);
        final color = _getEventColor(event.type);
        return Card(child: ListTile(leading: Icon(icon, color: color), title: Text(event.description ?? event.type), subtitle: Text(event.timestamp.toString().split('.')[0], style: const TextStyle(fontSize: 12)), trailing: event.type == 'snapshot' ? const Icon(Icons.image) : event.type == 'unlock' ? const Icon(Icons.lock_open) : null, onTap: () { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Event: ${event.description ?? event.type}'))); }));
      },
    );
  }

  IconData _getEventIcon(String type) {
    switch (type) {
      case 'snapshot':
        return Icons.camera;
      case 'motion':
        return Icons.directions_run;
      case 'unlock':
        return Icons.lock_open;
      case 'failed_code':
        return Icons.warning;
      case 'message':
        return Icons.speaker;
      default:
        return Icons.info;
    }
  }

  Color _getEventColor(String type) {
    switch (type) {
      case 'snapshot':
        return Colors.blue;
      case 'motion':
        return Colors.orange;
      case 'unlock':
        return Colors.green;
      case 'failed_code':
        return Colors.red;
      case 'message':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }
}
