package com.ankit.aitrader

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Worker
import androidx.work.WorkerParameters

class WatchdogWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
        val engineState = prefs.getString("engine_state", "STOPPED")
        val lastHeartbeat = prefs.getLong("last_heartbeat", 0L)
        val now = System.currentTimeMillis()

        if (engineState == "RUNNING" &&
            (!TradingForegroundService.isRunning ||
                !TradingForegroundService.isDartEngineInitialized ||
                (now - lastHeartbeat > 5 * 60 * 1000L))
        ) {
            try {
                val serviceIntent = Intent(applicationContext, TradingForegroundService::class.java).apply {
                    action = TradingForegroundService.ACTION_START
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    applicationContext.startForegroundService(serviceIntent)
                } else {
                    applicationContext.startService(serviceIntent)
                }
            } catch (e: Exception) {
                showFallbackNotification("Ankit AI Trader stopped – tap to restart")
            }
        }
        return Result.success()
    }

    private fun showFallbackNotification(message: String) {
        val channelId = "watchdog_channel"
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Watchdog Alerts",
                NotificationManager.IMPORTANCE_HIGH
            )
            manager?.createNotificationChannel(channel)
        }
        val intent = Intent(applicationContext, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(applicationContext, channelId)
            .setContentTitle("Ankit AI Trader Watchdog")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        manager?.notify(99, notification)
    }
}
