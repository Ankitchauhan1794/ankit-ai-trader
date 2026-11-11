package com.ankit.aitrader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class TradingForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "AnkitTradingEngineChannel"
        const val ALERT_CHANNEL_ID = "AnkitTradeAlertsChannel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.ankit.aitrader.START_SERVICE"
        const val ACTION_STOP = "com.ankit.aitrader.STOP_SERVICE"
        private const val WORKER_CHANNEL = "com.ankit.aitrader/background_worker"

        @Volatile
        var isServiceAlive: Boolean = false

        @Volatile
        var isDartEngineReady: Boolean = false

        @Volatile
        var isInitializingEngine: Boolean = false

        @Volatile
        var lastHeartbeatEpochMs: Long = 0L

        @Volatile
        var lastStartupError: String? = null

        @Volatile
        var lastShutdownReason: String? = null

        private var backgroundEngine: FlutterEngine? = null
        private var workerChannel: MethodChannel? = null
        private val mainHandler = Handler(Looper.getMainLooper())
        private val pendingReadyCallbacks = mutableListOf<(Boolean, String?) -> Unit>()

        fun ensureServiceAndEngineStarted(context: Context) {
            mainHandler.post {
                initBackgroundFlutterEngine(context.applicationContext)
            }
        }

        fun waitForServiceAndEngineReady(
            context: Context,
            timeoutMs: Long = 4500L,
            callback: (Boolean, String?) -> Unit
        ) {
            ensureServiceAndEngineStarted(context)
            val startAt = System.currentTimeMillis()

            fun poll() {
                if (isServiceAlive && isDartEngineReady && workerChannel != null) {
                    callback(true, null)
                    return
                }
                if (!isInitializingEngine && lastStartupError != null && !isDartEngineReady) {
                    callback(false, lastStartupError)
                    return
                }
                val elapsed = System.currentTimeMillis() - startAt
                if (elapsed >= timeoutMs) {
                    val err = lastStartupError
                        ?: if (!isServiceAlive) {
                            "Foreground service did not enter alive state within ${timeoutMs}ms"
                        } else {
                            "Background Dart isolate did not acknowledge readiness within ${timeoutMs}ms"
                        }
                    lastStartupError = err
                    callback(false, err)
                    return
                }
                mainHandler.postDelayed({ poll() }, 100L)
            }

            mainHandler.post { poll() }
        }

        private fun initBackgroundFlutterEngine(appContext: Context) {
            if (backgroundEngine != null && isDartEngineReady && workerChannel != null) {
                return
            }
            if (isInitializingEngine) {
                return
            }
            isInitializingEngine = true
            lastStartupError = null
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(appContext)
                loader.ensureInitializationComplete(appContext, null)

                val engine = backgroundEngine ?: FlutterEngine(appContext).also { created ->
                    try {
                        io.flutter.plugins.GeneratedPluginRegistrant.registerWith(created)
                    } catch (_: Throwable) {
                    }
                }

                val channel = MethodChannel(engine.dartExecutor.binaryMessenger, WORKER_CHANNEL)
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "acknowledgeEngineInitialized" -> {
                            isDartEngineReady = true
                            isInitializingEngine = false
                            lastStartupError = null
                            lastHeartbeatEpochMs = System.currentTimeMillis()
                            flushPendingReadyCallbacks(true, null)
                            result.success(true)
                        }
                        "updateServiceNotification" -> {
                            lastHeartbeatEpochMs = System.currentTimeMillis()
                            val title = call.argument<String>("title") ?: "Ankit AI Trader"
                            val text = call.argument<String>("text") ?: "Paper Trading Engine Active"
                            updateForegroundNotificationSafe(appContext, title, text)
                            result.success(true)
                        }
                        "postTradeAlertNotification" -> {
                            lastHeartbeatEpochMs = System.currentTimeMillis()
                            val alertId = call.argument<String>("alertId") ?: "ALERT"
                            val title = call.argument<String>("title") ?: "Ankit AI Trader Alert"
                            val body = call.argument<String>("body") ?: ""
                            postHighPriorityTradeAlert(appContext, alertId, title, body)
                            result.success(true)
                        }
                        "reportEngineFatalError" -> {
                            val err = call.argument<String>("error") ?: "Fatal background Dart engine error"
                            lastStartupError = err
                            isInitializingEngine = false
                            isDartEngineReady = false
                            flushPendingReadyCallbacks(false, err)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }
                workerChannel = channel
                if (backgroundEngine == null) {
                    backgroundEngine = engine
                    val appBundlePath = loader.findAppBundlePath()
                    val entrypoint = DartExecutor.DartEntrypoint(appBundlePath, "backgroundServiceMain")
                    engine.dartExecutor.executeDartEntrypoint(entrypoint)
                }
            } catch (e: Throwable) {
                isDartEngineReady = false
                isInitializingEngine = false
                lastStartupError = "Headless FlutterEngine init failed: ${e.message ?: e.toString()}"
                flushPendingReadyCallbacks(false, lastStartupError)
            }
        }

        private fun flushPendingReadyCallbacks(ok: Boolean, error: String?) {
            val copy = ArrayList(pendingReadyCallbacks)
            pendingReadyCallbacks.clear()
            for (cb in copy) {
                try {
                    cb(ok, error)
                } catch (_: Throwable) {
                }
            }
        }

        fun dispatchCommandToDartEngine(
            context: Context,
            command: String,
            callback: (Boolean, String?) -> Unit
        ) {
            waitForServiceAndEngineReady(context, timeoutMs = 4500L) { ready, readyErr ->
                if (!ready) {
                    callback(false, readyErr ?: "Background service & Dart engine not ready")
                    return@waitForServiceAndEngineReady
                }
                invokeCommandWithRetry(command, attempt = 0, maxAttempts = 15, callback = callback)
            }
        }

        private fun invokeCommandWithRetry(
            command: String,
            attempt: Int,
            maxAttempts: Int,
            callback: (Boolean, String?) -> Unit
        ) {
            val ch = workerChannel
            if (ch == null) {
                callback(false, "Background worker MethodChannel is null")
                return
            }
            try {
                ch.invokeMethod(
                    "handleCommand",
                    mapOf("command" to command),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            lastHeartbeatEpochMs = System.currentTimeMillis()
                            val ok = (result as? Boolean) ?: false
                            if (!ok) {
                                lastStartupError = "Background engine rejected command '$command'"
                            } else {
                                lastStartupError = null
                            }
                            callback(ok, lastStartupError)
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?
                        ) {
                            val err = "Background command '$command' error ($errorCode): ${errorMessage ?: "Unknown"}"
                            lastStartupError = err
                            callback(false, err)
                        }

                        override fun notImplemented() {
                            if (attempt < maxAttempts) {
                                mainHandler.postDelayed({
                                    invokeCommandWithRetry(command, attempt + 1, maxAttempts, callback)
                                }, 150L)
                            } else {
                                val err = "Background command '$command' notImplemented after ${maxAttempts + 1} attempts"
                                lastStartupError = err
                                callback(false, err)
                            }
                        }
                    }
                )
            } catch (e: Throwable) {
                val err = "Exception invoking '$command' on background engine: ${e.message ?: e.toString()}"
                lastStartupError = err
                callback(false, err)
            }
        }

        fun notifyNetworkTransition(connected: Boolean) {
            mainHandler.post {
                try {
                    workerChannel?.invokeMethod(
                        "onNetworkChanged",
                        mapOf("connected" to connected)
                    )
                } catch (_: Exception) {
                }
            }
        }

        private fun updateForegroundNotificationSafe(context: Context, title: String, text: String) {
            try {
                val manager = context.getSystemService(NotificationManager::class.java)
                val notificationIntent = Intent(context, MainActivity::class.java)
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    notificationIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val notif = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.stat_notify_sync)
                    .setContentIntent(pendingIntent)
                    .setOngoing(true)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .build()
                manager?.notify(NOTIFICATION_ID, notif)
            } catch (_: Throwable) {
            }
        }

        private fun postHighPriorityTradeAlert(
            context: Context,
            alertId: String,
            title: String,
            body: String
        ) {
            try {
                val manager = context.getSystemService(NotificationManager::class.java)
                val notificationIntent = Intent(context, MainActivity::class.java)
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    alertId.hashCode(),
                    notificationIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val notif = NotificationCompat.Builder(context, ALERT_CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setSmallIcon(android.R.drawable.stat_notify_more)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build()
                manager?.notify( NOTIFICATION_ID + (alertId.hashCode() and 0x0FFF), notif)
            } catch (_: Throwable) {
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        if (action == ACTION_STOP) {
            val reason = intent?.getStringExtra("shutdown_reason") ?: "Stopped by user"
            stopEngine(reason)
            stopSelf()
            return START_NOT_STICKY
        }

        isServiceAlive = true
        lastShutdownReason = null
        lastHeartbeatEpochMs = System.currentTimeMillis()
        createNotificationChannels()
        startForeground(
            NOTIFICATION_ID,
            buildNotification("Ankit AI Trader", "Paper Trading Engine Active")
        )
        acquireWakeLockSafe()
        saveState("RUNNING")
        ensureServiceAndEngineStarted(applicationContext)

        val cmd = intent?.getStringExtra("engine_command")
        if (!cmd.isNullOrEmpty()) {
            dispatchCommandToDartEngine(applicationContext, cmd) { _, _ -> }
        }

        return START_STICKY
    }

    private fun acquireWakeLockSafe() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "AnkitAITrader::EngineWakeLock"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            if (wakeLock?.isHeld != true) {
                wakeLock?.acquire(30 * 60 * 1000L)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopEngine(reason: String = "Foreground service stopped") {
        isServiceAlive = false
        lastShutdownReason = reason
        saveState("STOPPED")
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {
        }
    }

    private fun saveState(state: String) {
        val prefs = getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
        prefs.edit().putString("engine_state", state).apply()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val engineChannel = NotificationChannel(
                CHANNEL_ID,
                "Ankit AI Trader Engine",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Runs the self-healing background paper trading process"
            }
            val alertChannel = NotificationChannel(
                ALERT_CHANNEL_ID,
                "Ankit AI Trader Trade Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Trade entry, exit, and risk supervisor alerts"
            }
            manager?.createNotificationChannel(engineChannel)
            manager?.createNotificationChannel(alertChannel)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onDestroy() {
        stopEngine(lastShutdownReason ?: "Android service onDestroy invoked")
        super.onDestroy()
    }
}
