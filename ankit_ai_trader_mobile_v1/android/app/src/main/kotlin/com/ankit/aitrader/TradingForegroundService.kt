package com.ankit.aitrader

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class TradingForegroundService : Service() {

    companion object {
        private const val TAG = "AnkitAITraderFGS"
        private const val BG_CHANNEL = "com.ankit.aitrader/background_worker"
        private const val PREFS_NAME = "AnkitPrefs"
        private const val KEY_ENGINE_STATE = "engine_state"
        private const val KEY_LAST_HEARTBEAT = "last_heartbeat"

        const val SERVICE_CHANNEL_ID = "ankit_trader_service"
        const val TRADE_ALERTS_CHANNEL_ID = "trade_alerts_channel"
        const val TRADE_ALERTS_CHANNEL_NAME = "Trade Alerts"
        const val SERVICE_NOTIFICATION_ID = 1001

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

        @Volatile
        private var activeInstance: TradingForegroundService? = null

        fun syncDesiredStateToPrefs(context: Context, state: String) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_ENGINE_STATE, state)
                .apply()
        }

        fun recordHeartbeatToPrefs(context: Context, epochMs: Long) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putLong(KEY_LAST_HEARTBEAT, epochMs)
                .apply()
        }

        fun dispatchCommandToAuthoritativeEngine(
            command: String,
            callback: (Boolean, String?) -> Unit
        ) {
            val instance = activeInstance
            val channel = instance?.backgroundChannel
            if (instance == null || channel == null || !isRunning || !isDartEngineInitialized) {
                callback(false, lastStartupError ?: "Authoritative background service is not active")
                return
            }
            instance.handler.post {
                try {
                    when (command) {
                        "START" -> syncDesiredStateToPrefs(instance.applicationContext, "RUNNING")
                        "PAUSE" -> syncDesiredStateToPrefs(instance.applicationContext, "PAUSED")
                        "STOP", "RESET" -> syncDesiredStateToPrefs(instance.applicationContext, "STOPPED")
                    }
                    channel.invokeMethod(
                        "onCommand",
                        mapOf("command" to command),
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                val ok = (result as? Boolean) ?: false
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

        fun notifyNetworkTransition(connected: Boolean) {
            val instance = activeInstance
            val channel = instance?.backgroundChannel
            if (instance == null || channel == null || !isRunning || !isDartEngineInitialized) {
                return
            }
            instance.handler.post {
                try {
                    channel.invokeMethod("onNetworkChanged", mapOf("connected" to connected))
                } catch (e: Exception) {
                    Log.e(TAG, "notifyNetworkTransition failed", e)
                }
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var backgroundEngine: FlutterEngine? = null
    private var backgroundChannel: MethodChannel? = null
    private var connectivityManager: ConnectivityManager? = null
    private var serviceNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var consecutiveTickFailures: Int = 0
    private var currentTitle: String = "Ankit AI Trader — PAPER BOT ACTIVE"
    private var currentText: String = "Eq: $100.00 | BTC: -- | ETH: --"

    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (!isRunning) return
            try {
                acquireOrRenewWakeLock()
                val channel = backgroundChannel
                if (channel != null && isDartEngineInitialized) {
                    var responded = false
                    val tickTimestamp = System.currentTimeMillis()
                    handler.postDelayed({
                        if (!responded && isRunning) {
                            consecutiveTickFailures++
                            lastHeartbeatTickError = "onBackgroundTick timed out after 15s (failures=$consecutiveTickFailures)"
                            Log.e(TAG, lastHeartbeatTickError!!)
                            if (consecutiveTickFailures >= 2) {
                                restartHeadlessFlutterEngine("Dart isolate unresponsive for 2 consecutive ticks")
                            }
                        }
                    }, 15_000L)

                    channel.invokeMethod(
                        "onBackgroundTick",
                        null,
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                responded = true
                                consecutiveTickFailures = 0
                                lastHeartbeatTickError = null
                                lastNativeHeartbeatEpochMs = tickTimestamp
                                recordHeartbeatToPrefs(applicationContext, tickTimestamp)
                            }

                            override fun error(
                                errorCode: String,
                                errorMessage: String?,
                                errorDetails: Any?
                            ) {
                                responded = true
                                consecutiveTickFailures++
                                lastHeartbeatTickError = "onBackgroundTick error: $errorCode ($errorMessage)"
                                Log.e(TAG, lastHeartbeatTickError!!)
                                if (consecutiveTickFailures >= 2) {
                                    restartHeadlessFlutterEngine(lastHeartbeatTickError!!)
                                }
                            }

                            override fun notImplemented() {
                                responded = true
                                consecutiveTickFailures++
                                lastHeartbeatTickError = "onBackgroundTick notImplemented"
                                Log.w(TAG, lastHeartbeatTickError!!)
                            }
                        }
                    )
                } else {
                    Log.w(TAG, "Heartbeat tick: Dart engine not yet initialized, attempting ensureHeadlessFlutterEngine")
                    ensureHeadlessFlutterEngine()
                }
            } catch (e: Exception) {
                lastHeartbeatTickError = "Heartbeat runnable exception: ${e.message}"
                Log.e(TAG, lastHeartbeatTickError!!, e)
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
            recordHeartbeatToPrefs(applicationContext, lastNativeHeartbeatEpochMs)
            registerServiceNetworkCallback()
            ensureHeadlessFlutterEngine()
            handler.removeCallbacks(heartbeatRunnable)
            handler.postDelayed(heartbeatRunnable, 15_000L)
        } catch (e: Exception) {
            isRunning = false
            isDartEngineInitialized = false
            lastStartupError = "Foreground service onCreate failed: ${e.message}"
            Log.e(TAG, lastStartupError!!, e)
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE_BOT -> {
                syncDesiredStateToPrefs(applicationContext, "PAUSED")
                dispatchCommandToAuthoritativeEngine("PAUSE") { _, _ -> }
                return START_STICKY
            }
            ACTION_STOP_BOT -> {
                syncDesiredStateToPrefs(applicationContext, "STOPPED")
                dispatchCommandToAuthoritativeEngine("STOP") { _, _ ->
                    stopSelf()
                }
                return START_NOT_STICKY
            }
        }

        val title = intent?.getStringExtra(EXTRA_TITLE)
        val text = intent?.getStringExtra(EXTRA_TEXT)
        if (!title.isNullOrBlank()) currentTitle = title
        if (!text.isNullOrBlank()) currentText = text

        if (isRunning) {
            acquireOrRenewWakeLock()
            ensureHeadlessFlutterEngine()
            val nm = getSystemService(NotificationManager::class.java)
            nm?.notify(SERVICE_NOTIFICATION_ID, buildServiceNotification(currentTitle, currentText))
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        val prefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val desiredState = prefs.getString(KEY_ENGINE_STATE, "STOPPED")
        if (desiredState == "RUNNING") {
            try {
                val restartIntent = Intent(applicationContext, TradingForegroundService::class.java).apply {
                    action = ACTION_START
                    putExtra(EXTRA_TITLE, currentTitle)
                    putExtra(EXTRA_TEXT, currentText)
                }
                val pendingFlags = PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
                val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    PendingIntent.getForegroundService(applicationContext, 1002, restartIntent, pendingFlags)
                } else {
                    PendingIntent.getService(applicationContext, 1002, restartIntent, pendingFlags)
                }
                val alarmManager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager
                alarmManager?.set(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + 3_000L,
                    pendingIntent
                )
            } catch (e: Exception) {
                Log.e(TAG, "onTaskRemoved restart alarm scheduling failed", e)
            }
        }
    }

    private fun restartHeadlessFlutterEngine(reason: String) {
        Log.w(TAG, "Restarting headless FlutterEngine: $reason")
        try {
            isDartEngineInitialized = false
            backgroundEngine?.destroy()
        } catch (e: Exception) {
            Log.e(TAG, "Error destroying hung FlutterEngine", e)
        } finally {
            backgroundEngine = null
            backgroundChannel = null
            consecutiveTickFailures = 0
            ensureHeadlessFlutterEngine()
        }
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
                        consecutiveTickFailures = 0
                        val now = System.currentTimeMillis()
                        lastNativeHeartbeatEpochMs = now
                        recordHeartbeatToPrefs(applicationContext, now)
                        result.success(true)
                    }
                    "syncUserIntention" -> {
                        val intention = call.argument<String>("intention") ?: "STOPPED"
                        syncDesiredStateToPrefs(applicationContext, intention.uppercase())
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
                        val title = call.argument<String>("title")
                        val text = call.argument<String>("text")
                        if (!title.isNullOrBlank()) currentTitle = title
                        if (!text.isNullOrBlank()) currentText = text
                        val nm = getSystemService(NotificationManager::class.java)
                        nm?.notify(
                            SERVICE_NOTIFICATION_ID,
                            buildServiceNotification(currentTitle, currentText)
                        )
                        result.success(true)
                    }
                    "postTradeAlertNotification" -> {
                        val alertId = call.argument<String>("alertId")
                            ?: "ALERT_${System.currentTimeMillis()}"
                        val title = call.argument<String>("title") ?: "PAPER TRADE ALERT"
                        val body = call.argument<String>("body") ?: "[PAPER TRADE]"
                        val posted = postDismissibleTradeAlert(alertId, title, body)
                        result.success(posted)
                    }
                    else -> result.notImplemented()
                }
            }

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundServiceMain"
            )
            engine.dartExecutor.executeDartEntrypoint(entrypoint)
            backgroundEngine = engine
            backgroundChannel = channel
        } catch (e: Exception) {
            isDartEngineInitialized = false
            lastStartupError = "Headless Dart engine failed to initialize: ${e.message}"
            Log.e(TAG, lastStartupError!!, e)
        }
    }

    private fun registerServiceNetworkCallback() {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            connectivityManager = cm
            unregisterServiceNetworkCallback()
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    notifyNetworkTransition(true)
                    MainActivity.forwardNetworkEventToUi(true)
                }

                override fun onLost(network: Network) {
                    val stillConnected = isInternetAvailable(cm)
                    notifyNetworkTransition(stillConnected)
                    MainActivity.forwardNetworkEventToUi(stillConnected)
                }

                override fun onCapabilitiesChanged(
                    network: Network,
                    networkCapabilities: NetworkCapabilities
                ) {
                    val validated = networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                        networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    notifyNetworkTransition(validated)
                    MainActivity.forwardNetworkEventToUi(validated)
                }
            }
            serviceNetworkCallback = callback
            cm.registerDefaultNetworkCallback(callback)
        } catch (e: Exception) {
            Log.e(TAG, "registerServiceNetworkCallback failed", e)
        }
    }

    private fun unregisterServiceNetworkCallback() {
        val cm = connectivityManager
        val cb = serviceNetworkCallback
        if (cm != null && cb != null) {
            try {
                cm.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
            }
        }
        serviceNetworkCallback = null
    }

    private fun isInternetAvailable(cm: ConnectivityManager): Boolean {
        val active = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(active) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun canPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                return false
            }
        }
        val nm = getSystemService(NotificationManager::class.java)
        return nm?.areNotificationsEnabled() ?: true
    }

    private fun postDismissibleTradeAlert(alertId: String, title: String, body: String): Boolean {
        if (!canPostNotifications()) return false
        val nm = getSystemService(NotificationManager::class.java) ?: return false
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, TRADE_ALERTS_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        nm.notify(alertId.hashCode(), notification)
        return true
    }

    private fun acquireOrRenewWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = wakeLock ?: pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "AnkitAITrader::PaperEngineWakeLock"
            ).apply {
                setReferenceCounted(false)
                wakeLock = this
            }
            wl.acquire(15 * 60 * 1000L)
        } catch (e: Exception) {
            Log.e(TAG, "acquireOrRenewWakeLock failed", e)
        }
    }

    override fun onDestroy() {
        isRunning = false
        isDartEngineInitialized = false
        activeInstance = null
        handler.removeCallbacksAndMessages(null)
        unregisterServiceNetworkCallback()
        wakeLock?.let {
            if (it.isHeld) it.release()
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

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java) ?: return
            val serviceChannel = NotificationChannel(
                SERVICE_CHANNEL_ID,
                "Trading service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when the Ankit AI Trader authoritative paper engine is active."
            }
            val alertsChannel = NotificationChannel(
                TRADE_ALERTS_CHANNEL_ID,
                TRADE_ALERTS_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "High-importance alerts for simulated PAPER TRADE entries, exits, and safety locks."
            }
            nm.createNotificationChannel(serviceChannel)
            nm.createNotificationChannel(alertsChannel)
        }
    }

    private fun buildServiceActionPendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, TradingForegroundService::class.java).apply {
            this.action = action
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getService(this, requestCode, intent, flags)
    }

    private fun buildServiceNotification(title: String, text: String): Notification {
        val openActivityIntent = Intent(this, MainActivity::class.java)
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openActivityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val pausePendingIntent = buildServiceActionPendingIntent(ACTION_PAUSE_BOT, 2001)
        val stopPendingIntent = buildServiceActionPendingIntent(ACTION_STOP_BOT, 2002)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, SERVICE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val pauseAction = Notification.Action.Builder(null, "PAUSE", pausePendingIntent).build()
        val stopAction = Notification.Action.Builder(null, "STOP", stopPendingIntent).build()

        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(contentPendingIntent)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .addAction(pauseAction)
            .addAction(stopAction)
            .setOngoing(true)
            .build()
    }
}
