package com.ankit.aitrader

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SERVICE_CHANNEL = "com.ankit.aitrader/service"
        private const val NETWORK_EVENTS = "com.ankit.aitrader/network_events"
        private const val REQ_POST_NOTIFICATIONS = 2401
    }

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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
                    val title = call.argument<String>("title") ?: "Ankit AI Trader — PAPER BOT ACTIVE"
                    val text = call.argument<String>("text")
                        ?: "Authoritative background paper engine running."
                    val intent = Intent(this, TradingForegroundService::class.java).apply {
                        action = TradingForegroundService.ACTION_START
                        putExtra(TradingForegroundService.EXTRA_TITLE, title)
                        putExtra(TradingForegroundService.EXTRA_TEXT, text)
                    }
                    try {
                        TradingForegroundService.lastStartupError = null
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        awaitServiceAndDartInitialization(result, attemptsRemaining = 25)
                    } catch (e: Exception) {
                        TradingForegroundService.lastStartupError = e.message ?: "Start exception"
                        result.error("SERVICE_START_FAILED", e.message, null)
                    }
                }
                "dispatchCommand" -> {
                    val command = call.argument<String>("command") ?: ""
                    if (command.isEmpty()) {
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
                    TradingForegroundService.dispatchCommandToAuthoritativeEngine(command) { ok, errMsg ->
                        mainHandler.post {
                            if (ok) {
                                result.success(true)
                            } else {
                                result.error("COMMAND_FAILED", errMsg ?: "Background command failed", null)
                            }
                        }
                    }
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "Ankit AI Trader — PAPER BOT ACTIVE"
                    val text = call.argument<String>("text") ?: "Paper mode active"
                    val intent = Intent(this, TradingForegroundService::class.java).apply {
                        action = TradingForegroundService.ACTION_UPDATE
                        putExtra(TradingForegroundService.EXTRA_TITLE, title)
                        putExtra(TradingForegroundService.EXTRA_TEXT, text)
                    }
                    try {
                        if (TradingForegroundService.isRunning) {
                            startService(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopService" -> {
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
                    result.success(
                        mapOf(
                            "serviceRunning" to TradingForegroundService.isRunning,
                            "dartEngineInitialized" to TradingForegroundService.isDartEngineInitialized,
                            "lastError" to (TradingForegroundService.lastStartupError ?: "")
                        )
                    )
                }
                "checkNetworkConnected" -> {
                    result.success(isInternetAvailable())
                }
                "checkNotificationPermission" -> {
                    result.success(isNotificationPermissionGranted())
                }
                "requestNotificationPermission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED
                            ) {
                                requestPermissions(
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                    REQ_POST_NOTIFICATIONS
                                )
                            }
                        }
                        result.success(isNotificationPermissionGranted())
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "openNotificationSettings" -> {
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            }
                        } else {
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.fromParts("package", packageName, null)
                            }
                        }
                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "openBatterySettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NETWORK_EVENTS
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                registerConnectivityCallback()
                runOnUiThread {
                    eventSink?.success(isInternetAvailable())
                }
            }

            override fun onCancel(arguments: Any?) {
                unregisterConnectivityCallback()
                eventSink = null
            }
        })
    }

    private fun isNotificationPermissionGranted(): Boolean {
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

    private fun awaitServiceAndDartInitialization(
        result: MethodChannel.Result,
        attemptsRemaining: Int
    ) {
        if (TradingForegroundService.lastStartupError != null) {
            result.error(
                "SERVICE_INIT_ERROR",
                TradingForegroundService.lastStartupError,
                null
            )
            return
        }
        if (TradingForegroundService.isRunning &&
            TradingForegroundService.isDartEngineInitialized
        ) {
            result.success(true)
            return
        }
        if (attemptsRemaining <= 0) {
            result.error(
                "SERVICE_INIT_TIMEOUT",
                "Timed out waiting for TradingForegroundService and background Dart engine acknowledgement.",
                null
            )
            return
        }
        mainHandler.postDelayed(
            { awaitServiceAndDartInitialization(result, attemptsRemaining - 1) },
            200L
        )
    }

    private fun isInternetAvailable(): Boolean {
        val cm = connectivityManager ?: return false
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun registerConnectivityCallback() {
        unregisterConnectivityCallback()
        val cm = connectivityManager ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                TradingForegroundService.notifyNetworkTransition(true)
                runOnUiThread {
                    eventSink?.success(true)
                }
            }

            override fun onLost(network: Network) {
                val nowAvailable = isInternetAvailable()
                TradingForegroundService.notifyNetworkTransition(nowAvailable)
                runOnUiThread {
                    eventSink?.success(nowAvailable)
                }
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities
            ) {
                val validated =
                    networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                        networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                TradingForegroundService.notifyNetworkTransition(validated)
                runOnUiThread {
                    eventSink?.success(validated)
                }
            }
        }
        networkCallback = callback
        cm.registerDefaultNetworkCallback(callback)
    }

    private fun unregisterConnectivityCallback() {
        val cm = connectivityManager ?: return
        networkCallback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
    }

    override fun onDestroy() {
        unregisterConnectivityCallback()
        super.onDestroy()
    }
}
