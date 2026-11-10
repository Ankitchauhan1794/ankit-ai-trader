package com.ankit.aitrader

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val SERVICE_CHANNEL = "com.ankit.aitrader/service"
        private const val NETWORK_EVENTS = "com.ankit.aitrader/network_events"
        private const val REQ_POST_NOTIFICATIONS = 4001
        private const val START_POLL_INTERVAL_MS = 500L
        private const val START_TIMEOUT_ATTEMPTS = 40

        @Volatile
        private var activeEventSink: EventChannel.EventSink? = null
        private val uiHandler = Handler(Looper.getMainLooper())

        fun forwardNetworkEventToUi(connected: Boolean) {
            uiHandler.post {
                activeEventSink?.success(connected)
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var connectivityManager: ConnectivityManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val title = call.argument<String>("title")
                        ?: "Ankit AI Trader — PAPER BOT ACTIVE"
                    val text = call.argument<String>("text")
                        ?: "Authoritative background paper engine running."
                    try {
                        val intent = Intent(this, TradingForegroundService::class.java).apply {
                            action = TradingForegroundService.ACTION_START
                            putExtra(TradingForegroundService.EXTRA_TITLE, title)
                            putExtra(TradingForegroundService.EXTRA_TEXT, text)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        awaitServiceAndDartInitialization(0, result)
                    } catch (e: Exception) {
                        TradingForegroundService.lastStartupError = e.message ?: "Start exception"
                        result.error("SERVICE_START_FAILED", e.message, null)
                    }
                }
                "stopService" -> {
                    TradingForegroundService.syncDesiredStateToPrefs(applicationContext, "STOPPED")
                    val intent = Intent(this, TradingForegroundService::class.java)
                    stopService(intent)
                    result.success(true)
                }
                "isServiceRunning" -> {
                    result.success(
                        TradingForegroundService.isRunning &&
                            TradingForegroundService.isDartEngineInitialized
                    )
                }
                "getServiceStatus" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                    val ignoringBatteryOptimizations = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm?.isIgnoringBatteryOptimizations(packageName) ?: false
                    } else {
                        true
                    }
                    result.success(
                        mapOf(
                            "serviceRunning" to TradingForegroundService.isRunning,
                            "dartEngineInitialized" to TradingForegroundService.isDartEngineInitialized,
                            "lastError" to TradingForegroundService.lastStartupError,
                            "lastHeartbeatTickError" to TradingForegroundService.lastHeartbeatTickError,
                            "lastNativeHeartbeatEpochMs" to TradingForegroundService.lastNativeHeartbeatEpochMs,
                            "ignoringBatteryOptimizations" to ignoringBatteryOptimizations
                        )
                    )
                }
                "dispatchCommand" -> {
                    val command = call.argument<String>("command") ?: ""
                    if (command.isBlank()) {
                        result.error("INVALID_COMMAND", "Command cannot be empty", null)
                        return@setMethodCallHandler
                    }
                    if (!TradingForegroundService.isRunning || !TradingForegroundService.isDartEngineInitialized) {
                        result.error(
                            "ENGINE_NOT_READY",
                            TradingForegroundService.lastStartupError
                                ?: "Authoritative background engine is not initialized.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    TradingForegroundService.dispatchCommandToAuthoritativeEngine(command) { ok, err ->
                        mainHandler.post {
                            if (ok) {
                                result.success(true)
                            } else {
                                result.error("COMMAND_FAILED", err ?: "Background command failed", null)
                            }
                        }
                    }
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "Ankit AI Trader"
                    val text = call.argument<String>("text") ?: "Paper mode active"
                    val intent = Intent(this, TradingForegroundService::class.java).apply {
                        action = TradingForegroundService.ACTION_UPDATE
                        putExtra(TradingForegroundService.EXTRA_TITLE, title)
                        putExtra(TradingForegroundService.EXTRA_TEXT, text)
                    }
                    startService(intent)
                    result.success(true)
                }
                "checkNetworkConnected" -> {
                    result.success(isInternetAvailable())
                }
                "notifyNetworkChanged" -> {
                    val connected = call.argument<Boolean>("connected") ?: isInternetAvailable()
                    TradingForegroundService.notifyNetworkTransition(connected)
                    result.success(true)
                }
                "checkNotificationPermission" -> {
                    result.success(isNotificationPermissionGranted())
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                REQ_POST_NOTIFICATIONS
                            )
                        }
                    }
                    result.success(isNotificationPermissionGranted())
                }
                "openNotificationSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        }
                        startActivity(intent)
                    } catch (_: Exception) {
                        val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.fromParts("package", packageName, null)
                        }
                        startActivity(fallback)
                    }
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                    val ignoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm?.isIgnoringBatteryOptimizations(packageName) ?: false
                    } else {
                        true
                    }
                    result.success(ignoring)
                }
                "openBatterySettings" -> {
                    openBatteryAndOemSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NETWORK_EVENTS
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                activeEventSink = events
                runOnUiThread {
                    activeEventSink?.success(isInternetAvailable())
                }
            }

            override fun onCancel(arguments: Any?) {
                activeEventSink = null
            }
        })
    }

    private fun openBatteryAndOemSettings() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (pm != null && !pm.isIgnoringBatteryOptimizations(packageName)) {
                    val reqIntent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(reqIntent)
                    return
                }
            }
        } catch (_: Exception) {
        }

        // OnePlus / OxygenOS / ColorOS specific background auto-launch settings fallback
        val oemComponents = listOf(
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
            ComponentName("com.oplus.battery", "com.oplus.powermanager.fuelgaue.PowerConsumptionActivity")
        )
        for (comp in oemComponents) {
            try {
                val oemIntent = Intent().apply { component = comp }
                if (packageManager.resolveActivity(oemIntent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                    startActivity(oemIntent)
                    return
                }
            } catch (_: Exception) {
            }
        }

        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
            startActivity(fallback)
        }
    }

    private fun isNotificationPermissionGranted(): Boolean {
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

    private fun awaitServiceAndDartInitialization(
        attempt: Int,
        result: MethodChannel.Result
    ) {
        val err = TradingForegroundService.lastStartupError
        if (!err.isNullOrBlank()) {
            result.error("SERVICE_INIT_ERROR", err, null)
            return
        }
        if (TradingForegroundService.isRunning && TradingForegroundService.isDartEngineInitialized) {
            result.success(true)
            return
        }
        if (attempt >= START_TIMEOUT_ATTEMPTS) {
            result.error(
                "SERVICE_INIT_TIMEOUT",
                TradingForegroundService.lastStartupError
                    ?: "Timed out waiting for background Dart engine initialization",
                null
            )
            return
        }
        mainHandler.postDelayed({
            awaitServiceAndDartInitialization(attempt + 1, result)
        }, START_POLL_INTERVAL_MS)
    }

    private fun isInternetAvailable(): Boolean {
        val active = connectivityManager.activeNetwork ?: return false
        val caps = connectivityManager.getNetworkCapabilities(active) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    override fun onDestroy() {
        activeEventSink = null
        super.onDestroy()
    }
}
