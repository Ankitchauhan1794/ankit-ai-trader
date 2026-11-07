import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  static const platform = MethodChannel('com.ankit.aitrader/battery');

  Future<void> _openBatterySettings() async {
    try {
      await platform.invokeMethod('openBatterySettings');
    } catch (e) {
      // fallback
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ankit AI Trader Dashboard')),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            color: Colors.amber.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('OnePlus & Battery Optimization', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  const Text('Status: Battery Optimization Active / Unrestricted Recommended'),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _openBatterySettings,
                    child: const Text('Open Battery Settings'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'OnePlus Steps:\nSettings -> Apps -> Ankit AI Trader -> Battery -> Unrestricted / Allow background activity / Auto-launch.\nNote: Android force-stop cannot be bypassed and 24/7 operation is not guaranteed.',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
