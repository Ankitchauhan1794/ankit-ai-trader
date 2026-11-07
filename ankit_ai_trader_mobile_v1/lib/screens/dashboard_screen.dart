import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class OnePlusBatteryOptimizationCard extends StatelessWidget {
  final bool ignoringBatteryOptimizations;
  final VoidCallback onOpenSettings;

  const OnePlusBatteryOptimizationCard({
    super.key,
    required this.ignoringBatteryOptimizations,
    required this.onOpenSettings,
  });

  static const MethodChannel _channel =
      MethodChannel('com.ankit.aitrader/service');

  static Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod('openBatterySettings');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: ignoringBatteryOptimizations
          ? const Color(0xFF132A1E)
          : const Color(0xFF33240F),
      child: ListTile(
        leading: Icon(
          ignoringBatteryOptimizations
              ? Icons.battery_charging_full
              : Icons.battery_alert,
          color: ignoringBatteryOptimizations
              ? Colors.greenAccent
              : Colors.orangeAccent,
        ),
        title: Text(
          ignoringBatteryOptimizations
              ? 'Background Battery Protection: UNRESTRICTED'
              : 'OnePlus / Android Battery Optimization Active',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        subtitle: Text(
          ignoringBatteryOptimizations
              ? '24/7 Foreground Service & WakeLock active for paper trading.'
              : 'Tap Fix to set Battery to "Don\'t optimize" / Allow Auto-Launch on OnePlus.',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: TextButton(
          onPressed: onOpenSettings,
          child: Text(ignoringBatteryOptimizations ? 'VERIFY' : 'FIX NOW'),
        ),
      ),
    );
  }
}
