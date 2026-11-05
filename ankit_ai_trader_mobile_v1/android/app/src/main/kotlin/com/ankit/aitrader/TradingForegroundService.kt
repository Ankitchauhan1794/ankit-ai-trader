package com.ankit.aitrader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class TradingForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "ankit_trader_service"
        private const val NOTIFICATION_ID = 1101
        private const val BG_CHANNEL = "com.ankit.aitrader/background_worker"

        const val ACTION_START = "com.ankit.aitrader.ACTION_START"
        const val ACTION_UPDATE = "com.ankit.aitrader.ACTION_UPDATE"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_TEXT = "extra_text"

        @Volatile
        var isRunning: Boolean = false

        @Volatile
        var isDartEngineInitialized: Boolean = false

        @Volatile
        var lastStartupError: String? = null

        private var activeInstance: TradingForegroundService? = null

        fun dispatchCommandToAuthoritativeEngine(
            command: String,
            callback: (Boolean, String?) -> Unit
        ) {
            val instance = activeInstance
            val ch = instance?.backgroundChannel
            if (instance == null || ch == null || !isRunning || !isDartEngineInitialized) {
                callback(false, lastStartupError ?: "Authoritative background service is not active")
                return
            }
            instance.handler.post {
                ch.invokeMethod(
                    "onCommand",
                    mapOf("command" to command),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            val ok = (result as? Boolean) ?: true
                            callback(ok, if (ok) null else "Background engine rejected command")
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?
                        ) {
                            callback(false, errorMessage ?: errorCode)
                        }

                        override fun notImplemented() {
                            callback(false, "Command handler not implemented in background isolate")
                        }
                    }
                )
            }
        }

        fun notifyNetworkTransition(isConnected: Boolean) {
            val instance = activeInstance ?: return
            val ch = instance.backgroundChannel ?: return
            if (!isRunning || !isDartEngineInitialized) return
            instance.handler.post {
                ch.invokeMethod("onNetworkChanged", mapOf("connected" to isConnected))
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var backgroundEngine: FlutterEngine? = null
    private var backgroundChannel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private var currentTitle = "Ankit AI Trader service active"
    private var currentText = "Authoritative paper engine ready. No live orders."

    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (!isRunning) return
            acquireOrRenewWakeLock()
            if (isDartEngineInitialized) {
                backgroundChannel?.invokeMethod("onBackgroundTick", null)
            }
            handler.postDelayed(this, 60_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        lastStartupError = null
        try {
            createNotificationChannel()
            acquireOrRenewWakeLock()
            val notification = buildNotification(currentTitle, currentText)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            isRunning = true
            ensureHeadlessFlutterEngine()
            handler.postDelayed(heartbeatRunnable, 30_000L)
        } catch (e: Exception) {
            isRunning = false
            isDartEngineInitialized = false
            lastStartupError = "Foreground service onCreate failed: ${e.message}"
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: currentTitle
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: currentText
        currentTitle = title
        currentText = text
        if (isRunning) {
            val manager = getSystemService(NotificationManager::class.java)
            manager?.notify(NOTIFICATION_ID, buildNotification(currentTitle, currentText))
        }
        return START_STICKY
    }

    private fun ensureHeadlessFlutterEngine() {
        if (backgroundEngine != null) return
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, BG_CHANNEL)
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "acknowledgeEngineInitialized" -> {
                        isDartEngineInitialized = true
                        lastStartupError = null
                        result.success(true)
                    }
                    "reportEngineFatalError" -> {
                        val err = call.argument<String>("error") ?: "Background engine failure"
                        isDartEngineInitialized = false
                        lastStartupError = err
                        result.success(true)
                    }
                    "updateServiceNotification" -> {
                        val title = call.argument<String>("title") ?: currentTitle
                        val text = call.argument<String>("text") ?: currentText
                        currentTitle = title
                        currentText = text
                        val manager = getSystemService(NotificationManager::class.java)
                        manager?.notify(NOTIFICATION_ID, buildNotification(currentTitle, currentText))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
            backgroundEngine = engine
            backgroundChannel = channel

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundServiceMain"
            )
            engine.dartExecutor.executeDartEntrypoint(entrypoint)
        } catch (e: Exception) {
            isDartEngineInitialized = false
            lastStartupError = "Headless Dart engine failed to initialize: ${e.message}"
        }
    }

    private fun acquireOrRenewWakeLock() {
        try {
            val existing = wakeLock
            if (existing != null && existing.isHeld) {
                existing.release()
            }
        } catch (_: Exception) {
        }
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "AnkitAITrader::PaperEngineWakeLock"
            )
            wl.setReferenceCounted(false)
            // Bounded 15-minute wake-lock lease renewed every 60-second heartbeat
            wl.acquire(15 * 60 * 1000L)
            wakeLock = wl
        } catch (_: Exception) {
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isRunning = false
        isDartEngineInitialized = false
        activeInstance = null
        handler.removeCallbacksAndMessages(null)
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (_: Exception) {
        }
        wakeLock = null
        try {
            backgroundEngine?.destroy()
        } catch (_: Exception) {
        }
        backgroundEngine = null
        backgroundChannel = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Trading service",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Shows when the Ankit AI Trader authoritative paper engine is active."
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_menu_myplaces)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .build()
    }
}
