import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class OnePlusBatteryOptimizationCard extends StatelessWidget {
  final bool ignoringBatteryOptimizations;
  final bool notificationPermissionGranted;
  final VoidCallback onOpenSettings;
  final VoidCallback? onOpenNotifications;

  const OnePlusBatteryOptimizationCard({
    super.key,
    required this.ignoringBatteryOptimizations,
    this.notificationPermissionGranted = true,
    required this.onOpenSettings,
    this.onOpenNotifications,
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
    final allHealthy =
        ignoringBatteryOptimizations && notificationPermissionGranted;
    return Card(
      color: allHealthy ? const Color(0xFF11221B) : const Color(0xFF2B1F11),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  allHealthy ? Icons.verified_user : Icons.warning_amber_rounded,
                  color: allHealthy
                      ? const Color(0xFF00E676)
                      : const Color(0xFFFF9100),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'OnePlus & Android Background Configuration',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '• Notification Permission: ${notificationPermissionGranted ? "GRANTED" : "BLOCKED"}',
              style: TextStyle(
                fontSize: 12,
                color: notificationPermissionGranted
                    ? const Color(0xFF00E676)
                    : const Color(0xFFFF5252),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '• Battery Optimization: ${ignoringBatteryOptimizations ? "UNRESTRICTED (Don\'t optimize)" : "OPTIMIZED (May kill service)"}',
              style: TextStyle(
                fontSize: 12,
                color: ignoringBatteryOptimizations
                    ? const Color(0xFF00E676)
                    : const Color(0xFFFF9100),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'OnePlus Steps:\n'
              '1. Settings → Battery → More settings → Optimize battery use → Ankit AI Trader → Don\'t optimize.\n'
              '2. Settings → Apps → App management → Ankit AI Trader → Battery usage → Allow background activity & Auto-launch.\n'
              'Note: Due to Android & OEM power management, this configuration improves survival but does not guarantee uninterrupted 24/7 execution.',
              style: TextStyle(fontSize: 11, color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.battery_saver, size: 16),
                  label: const Text('Open Battery Settings'),
                ),
                if (onOpenNotifications != null)
                  OutlinedButton.icon(
                    onPressed: onOpenNotifications,
                    icon: const Icon(Icons.notifications_active, size: 16),
                    label: const Text('Notification Settings'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
