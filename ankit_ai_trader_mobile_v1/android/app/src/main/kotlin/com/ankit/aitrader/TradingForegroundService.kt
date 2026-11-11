package com.ankit.aitrader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class TradingForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "AnkitTradingEngineChannel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.ankit.aitrader.START_SERVICE"
        const val ACTION_STOP = "com.ankit.aitrader.STOP_SERVICE"
    }

    @Volatile
    private var isRunning = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        if (action == ACTION_STOP) {
            stopEngine()
            stopSelf()
            return START_NOT_STICKY
        }

        if (!isRunning) {
            isRunning = true
            createNotificationChannel()
            startForeground(NOTIFICATION_ID, buildNotification("Engine Initializing..."))
            saveState("RUNNING")
            startPollingLoop()
        }

        return START_STICKY
    }

    private fun startPollingLoop() {
        thread(isDaemon = true, name = "AnkitNativeEngineThread") {
            while (isRunning) {
                try {
                    val statusText = pingBackendAndExecuteSync()
                    updateNotification(statusText)
                } catch (e: Exception) {
                    updateNotification("Sync Error: ${e.message}")
                }

                try {
                    Thread.sleep(10000)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
    }

    private fun pingBackendAndExecuteSync(): String {
        return try {
            val url = URL("https://httpbin.org/get")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "GET"
            conn.connectTimeout = 5000
            conn.readTimeout = 5000
            val code = conn.responseCode
            conn.disconnect()
            if (code == 200) "Engine Active | Backend Reachable" else "Engine Active | Status $code"
        } catch (e: Exception) {
            "Engine Active | Standalone Offline"
        }
    }

    private fun stopEngine() {
        isRunning = false
        saveState("STOPPED")
    }

    private fun saveState(state: String) {
        val prefs = getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
        prefs.edit().putString("engine_state", state).apply()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ankit AI Trader Engine",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Runs the self-healing background trading process"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ankit AI Trader Engine")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    override fun onDestroy() {
        stopEngine()
        super.onDestroy()
    }
}
