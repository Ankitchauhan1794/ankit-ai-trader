package com.ankit.aitrader

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class TradingForegroundService : Service() {
    companion object {
        private const val TAG = "AnkitAITraderFGS"
        private const val SERVICE_CHANNEL_ID = "ankit_trader_service"
        private const val TRADE_ALERTS_CHANNEL_ID = "trade_alerts_channel"
        private const val TRADE_ALERTS_CHANNEL_NAME = "Trade Alerts"
        private const val SERVICE_NOTIFICATION_ID = 1101
        private const val BG_CHANNEL = "com.ankit.aitrader/background_worker"

        const val ACTION_START = "com.ankit.aitrader.ACTION_START"
        const val ACTION_UPDATE = "com.ankit.aitrader.ACTION_UPDATE"
        const val ACTION_PAUSE_BOT = "com.ankit.aitrader.ACTION_PAUSE_BOT"
        const val ACTION_STOP_BOT = "com.ankit.aitrader.ACTION_STOP_BOT"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_TEXT = "extra_text"

        @Volatile
        var isRunning: Boolean = false

        @Volatile
        var isDartEngineInitialized: Boolean = false

        @Volatile
        var lastStartupError: String? = null

        @Volatile
        var lastHeartbeatTickError: String? = null

        @Volatile
        var lastNativeHeartbeatEpochMs: Long = 0L

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
                try {
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
                } catch (e: Exception) {
                    Log.e(TAG, "dispatchCommandToAuthoritativeEngine($command) failed", e)
                    callback(false, e.message ?: "Command invocation exception")
                }
            }
        }

        fun notifyNetworkTransition(isConnected: Boolean) {
            val instance = activeInstance ?: return
            val ch = instance.backgroundChannel ?: return
            if (!isRunning || !isDartEngineInitialized) return
            instance.handler.post {
                try {
                    ch.invokeMethod("onNetworkChanged", mapOf("connected" to isConnected))
                } catch (e: Exception) {
                    Log.e(TAG, "notifyNetworkTransition failed", e)
                }
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var backgroundEngine: FlutterEngine? = null
    private var backgroundChannel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private var currentTitle = "Ankit AI Trader — PAPER BOT ACTIVE"
    private var currentText = "Eq: $100.00 | BTC: -- | ETH: --"

    // Step 1(d): Heartbeat with Result callback and try/catch error logging on every tick.
    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (!isRunning) return
            try {
                acquireOrRenewWakeLock()
                lastNativeHeartbeatEpochMs = System.currentTimeMillis()
                if (isDartEngineInitialized) {
                    val ch = backgroundChannel
                    if (ch != null) {
                        ch.invokeMethod(
                            "onBackgroundTick",
                            null,
                            object : MethodChannel.Result {
                                override fun success(result: Any?) {
                                    lastHeartbeatTickError = null
                                }

                                override fun error(
                                    errorCode: String,
                                    errorMessage: String?,
                                    errorDetails: Any?
                                ) {
                                    val msg = "onBackgroundTick error: $errorCode ($errorMessage)"
                                    lastHeartbeatTickError = msg
                                    Log.e(TAG, msg)
                                }

                                override fun notImplemented() {
                                    val msg = "onBackgroundTick notImplemented in background isolate"
                                    lastHeartbeatTickError = msg
                                    Log.w(TAG, msg)
                                }
                            }
                        )
                    } else {
                        Log.w(TAG, "Heartbeat tick skipped: backgroundChannel is null")
                    }
                } else {
                    Log.w(TAG, "Heartbeat tick: Dart engine not yet initialized, attempting ensureHeadlessFlutterEngine")
                    ensureHeadlessFlutterEngine()
                }
            } catch (e: Exception) {
                val msg = "Heartbeat runnable exception: ${e.message}"
                lastHeartbeatTickError = msg
                Log.e(TAG, msg, e)
            } finally {
                if (isRunning) {
                    handler.postDelayed(this, 60_000L)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        lastStartupError = null
        try {
            createNotificationChannels()
            acquireOrRenewWakeLock()
            val notification = buildServiceNotification(currentTitle, currentText)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    SERVICE_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(SERVICE_NOTIFICATION_ID, notification)
            }
            isRunning = true
            lastNativeHeartbeatEpochMs = System.currentTimeMillis()
            ensureHeadlessFlutterEngine()
            handler.removeCallbacks(heartbeatRunnable)
            handler.postDelayed(heartbeatRunnable, 30_000L)
        } catch (e: Exception) {
            isRunning = false
            isDartEngineInitialized = false
            lastStartupError = "Foreground service onCreate failed: ${e.message}"
            Log.e(TAG, lastStartupError ?: "onCreate error", e)
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE_BOT -> {
                dispatchCommandToAuthoritativeEngine("PAUSE") { _, _ -> }
                return START_STICKY
            }
            ACTION_STOP_BOT -> {
                dispatchCommandToAuthoritativeEngine("STOP") { _, _ ->
                    stopSelf()
                }
                return START_NOT_STICKY
            }
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: currentTitle
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: currentText
        currentTitle = title
        currentText = text
        if (isRunning) {
            acquireOrRenewWakeLock()
            ensureHeadlessFlutterEngine()
            val manager = getSystemService(NotificationManager::class.java)
            manager?.notify(SERVICE_NOTIFICATION_ID, buildServiceNotification(currentTitle, currentText))
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
                        lastNativeHeartbeatEpochMs = System.currentTimeMillis()
                        result.success(true)
                    }
                    "reportEngineFatalError" -> {
                        val err = call.argument<String>("error") ?: "Background engine failure"
                        isDartEngineInitialized = false
                        lastStartupError = err
                        Log.e(TAG, "Background engine fatal error: $err")
                        result.success(true)
                    }
                    "updateServiceNotification" -> {
                        val title = call.argument<String>("title") ?: currentTitle
                        val text = call.argument<String>("text") ?: currentText
                        currentTitle = title
                        currentText = text
                        val manager = getSystemService(NotificationManager::class.java)
                        manager?.notify(
                            SERVICE_NOTIFICATION_ID,
                            buildServiceNotification(currentTitle, currentText)
                        )
                        result.success(true)
                    }
                    "postTradeAlertNotification" -> {
                        val alertId = call.argument<String>("alertId") ?: "ALERT_${System.currentTimeMillis()}"
                        val title = call.argument<String>("title") ?: "PAPER TRADE ALERT"
                        val body = call.argument<String>("body") ?: "[PAPER TRADE]"
                        val posted = postDismissibleTradeAlert(alertId, title, body)
                        result.success(posted)
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
            Log.e(TAG, lastStartupError ?: "Headless init failed", e)
        }
    }

    private fun canPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) return false
        }
        val manager = getSystemService(NotificationManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            manager.areNotificationsEnabled()
        } else {
            true
        }
    }

    /// Posts a normal dismissible high-importance notification on the "Trade Alerts" channel
    /// with a unique notification ID derived from `alertId`, never overwriting `SERVICE_NOTIFICATION_ID` (1101).
    private fun postDismissibleTradeAlert(alertId: String, title: String, body: String): Boolean {
        return try {
            if (!canPostNotifications()) {
                return false
            }
            val manager = getSystemService(NotificationManager::class.java) ?: return false
            var notificationId = (alertId.hashCode() and 0x7FFFFFFF)
            if (notificationId == SERVICE_NOTIFICATION_ID || notificationId < 2000) {
                notificationId += 2000
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, TRADE_ALERTS_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
                    .setPriority(Notification.PRIORITY_HIGH)
                    .setDefaults(Notification.DEFAULT_ALL)
            }

            val notification = builder
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setOngoing(false)
                .setAutoCancel(true)
                .build()

            manager.notify(notificationId, notification)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun acquireOrRenewWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = wakeLock ?: pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "AnkitAITrader::PaperEngineWakeLock"
            ).apply {
                setReferenceCounted(false)
            }
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

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java) ?: return

            // 1. Ongoing low-importance Foreground Service channel
            val serviceChannel = NotificationChannel(
                SERVICE_CHANNEL_ID,
                "Trading service",
                NotificationManager.IMPORTANCE_LOW
            )
            serviceChannel.description =
                "Shows when the Ankit AI Trader authoritative paper engine is active."
            manager.createNotificationChannel(serviceChannel)

            // 2. Separate high-importance "Trade Alerts" channel for entry, exit & safety lock alerts
            val alertsChannel = NotificationChannel(
                TRADE_ALERTS_CHANNEL_ID,
                TRADE_ALERTS_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            )
            alertsChannel.description =
                "High-importance alerts for simulated PAPER TRADE entries, exits, and safety locks."
            alertsChannel.enableVibration(true)
            manager.createNotificationChannel(alertsChannel)
        }
    }

    private fun buildServiceActionPendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, TradingForegroundService::class.java).apply {
            this.action = action
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getService(this, requestCode, intent, flags)
    }

    private fun buildServiceNotification(title: String, text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, SERVICE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val pausePendingIntent = buildServiceActionPendingIntent(ACTION_PAUSE_BOT, 3101)
        val stopPendingIntent = buildServiceActionPendingIntent(ACTION_STOP_BOT, 3102)

        val pauseAction = Notification.Action.Builder(
            android.R.drawable.ic_media_pause,
            "PAUSE",
            pausePendingIntent
        ).build()

        val stopAction = Notification.Action.Builder(
            android.R.drawable.ic_delete,
            "STOP",
            stopPendingIntent
        ).build()

        return builder
            .setSmallIcon(android.R.drawable.ic_menu_myplaces)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .addAction(pauseAction)
            .addAction(stopAction)
            .setOngoing(true)
            .build()
    }
}
