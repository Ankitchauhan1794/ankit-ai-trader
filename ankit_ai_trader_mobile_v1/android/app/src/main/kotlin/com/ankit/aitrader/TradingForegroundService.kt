package com.ankit.aitrader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.Capabilities
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class TradingForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit importConnectivityManager: ConnectivityManager
    private lateinit importNetworkCallback: ConnectivityManager.NetworkCallback

    companion object {
        const val CHANNEL_ID = "trading_channel"
        const val ACTION_START = "ACTION_START"
        const val ACTION_PAUSE = "ACTION_PAUSE"
        const val ACTION_STOP = "ACTION_STOP"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireWakeLock()
        setupNetworkCallback()
    }

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AnkitAITrader::ServiceWakeLock").apply {
            acquire(24 * 60 * 60 * 1000L) // 24 hours max
        }
    }

    private fun setupNetworkCallback() {
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                super.onAvailable(network)
                // Forward network recovery to engine bridge / shared prefs
                updateNetworkState(true)
            }
            override fun onLost(network: Network) {
                super.onLost(network)
                // Forward network loss to engine bridge
                updateNetworkState(false)
            }
        }
        connectivityManager.registerDefaultNetworkCallback(networkCallback)
    }

    private fun updateNetworkState(isOnline: Boolean) {
        val prefs = getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
        prefs.edit().putBoolean("is_online", isOnline).putLong("last_heartbeat", System.currentTimeMillis()).apply()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): START_STICKY {
        when (intent?.action) {
            ACTION_PAUSE -> handlePause()
            ACTION_STOP -> handleStop()
            else -> startForeground(1, buildNotification("BTC | ETH | Equity: $100 | State: RUNNING | Updated: " + getCurrentTime()))
        }
        return START_STICKY
    }

    private fun handlePause() {
        val prefs = getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
        prefs.edit().putString("engine_state", "PAUSED").putString("pause_reason", "user").apply()
        updateNotification("Engine State: PAUSED (User)")
    }

    private fun handleStop() {
        val prefs = getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
        prefs.edit().putString("engine_state", "STOPPED").putString("pause_reason", "stopped").apply()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Trading Engine Service Channel",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(serviceChannel)
        }
    }

    private fun buildNotification(contentText: String): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(this, 0, notificationIntent, PendingIntent.FLAG_IMMUTABLE)

        val pauseIntent = Intent(this, TradingForegroundService::class.java).apply { action = ACTION_PAUSE }
        val pausePending = PendingIntent.getService(this, 1, pauseIntent, PendingIntent.FLAG_IMMUTABLE)

        val stopIntent = Intent(this, TradingForegroundService::class.java).apply { action = ACTION_STOP }
        val stopPending = PendingIntent.getService(this, 2, stopIntent, PendingIntent.FLAG_IMMUTABLE)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ankit AI Trader Active")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "Pause", pausePending)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPending)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(1, buildNotification(text))
    }

    private fun getCurrentTime(): String {
        val sdf = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
        return sdf.format(java.util.Date())
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        try {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        } catch (e: Exception) {}
        wakeLock?.release()
        super.onDestroy()
    }
}
