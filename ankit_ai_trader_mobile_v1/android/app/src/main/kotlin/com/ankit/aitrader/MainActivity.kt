package com.ankit.aitrader

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val SERVICE_CHANNEL = "com.ankit.aitrader/service"
    private val LEGACY_CHANNEL = "com.ankit.aitrader/background_engine"
    private val NETWORK_EVENTS_CHANNEL = "com.ankit.aitrader/network_events"
    private var networkEventSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SERVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startOrEnsureService" -> {
                        startTradingService()
                        TradingForegroundService.waitForServiceAndEngineReady(
                            applicationContext,
                            timeoutMs = 4500L
                        ) { ready, _ ->
                            runOnUiThread { result.success(ready) }
                        }
                    }
                    "dispatchEngineCommand" -> {
                        val cmd = call.argument<String>("command") ?: "START"
                        if (!TradingForegroundService.isServiceAlive) {
                            startTradingService()
                        }
                        TradingForegroundService.dispatchCommandToDartEngine(
                            applicationContext,
                            cmd
                        ) { ok, _ ->
                            runOnUiThread { result.success(ok) }
                        }
                    }
                    "getServiceStatus" -> {
                        val status = mapOf(
                            "serviceRunning" to TradingForegroundService.isServiceAlive,
                            "dartEngineInitialized" to TradingForegroundService.isDartEngineReady,
                            "lastNativeHeartbeatEpochMs" to TradingForegroundService.lastHeartbeatEpochMs,
                            "ignoringBatteryOptimizations" to isBatteryOptimizationDisabled(),
                            "lastNativeError" to TradingForegroundService.lastStartupError,
                            "lastNativeShutdownReason" to TradingForegroundService.lastShutdownReason
                        )
                        result.success(status)
                    }
                    "stopService" -> {
                        val reason = call.argument<String>("reason") ?: "Stopped by user"
                        stopTradingService(reason)
                        result.success(true)
                    }
                    "checkNotificationPermission" -> {
                        result.success(hasNotificationPermission())
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermissionIfNeeded()
                        result.success(hasNotificationPermission())
                    }
                    "openNotificationSettings" -> {
                        openAppNotificationSettings()
                        result.success(true)
                    }
                    "openBatterySettings" -> {
                        requestDisableBatteryOptimization()
                        result.success(true)
                    }
                    "checkNetworkConnected" -> {
                        result.success(isNetworkConnected())
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LEGACY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        startTradingService()
                        TradingForegroundService.waitForServiceAndEngineReady(
                            applicationContext,
                            timeoutMs = 4500L
                        ) { ready, _ ->
                            runOnUiThread { result.success(ready) }
                        }
                    }
                    "stopService" -> {
                        stopTradingService("Stopped via legacy channel")
                        result.success(true)
                    }
                    "isServiceRunning" -> {
                        result.success(
                            TradingForegroundService.isServiceAlive &&
                                TradingForegroundService.isDartEngineReady
                        )
                    }
                    "requestBatteryOptimizations" -> {
                        requestDisableBatteryOptimization()
                        result.success(true)
                    }
                    "isBatteryOptimizationDisabled" -> {
                        result.success(isBatteryOptimizationDisabled())
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    networkEventSink = events
                    registerNetworkCallback()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterNetworkCallback()
                    networkEventSink = null
                }
            })
    }

    private fun startTradingService(command: String? = null) {
        val serviceIntent = Intent(this, TradingForegroundService::class.java).apply {
            action = TradingForegroundService.ACTION_START
            if (command != null) {
                putExtra("engine_command", command)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun stopTradingService(reason: String = "Stopped by user") {
        val serviceIntent = Intent(this, TradingForegroundService::class.java).apply {
            action = TradingForegroundService.ACTION_STOP
            putExtra("shutdown_reason", reason)
        }
        startService(serviceIntent)
    }

    private fun hasNotificationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 && !hasNotificationPermission()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                1002
            )
        }
    }

    private fun openAppNotificationSettings() {
        try {
            val intent = Intent().apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                } else {
                    action = Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    data = Uri.parse("package:$packageName")
                }
            }
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    private fun isBatteryOptimizationDisabled(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            return pm.isIgnoringBatteryOptimizations(packageName)
        }
        return true
    }

    private fun requestDisableBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                if (!isBatteryOptimizationDisabled()) {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                } else {
                    val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    startActivity(intent)
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun isNetworkConnected(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val net = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(net) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } catch (_: Exception) {
            true
        }
    }

    private fun registerNetworkCallback() {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    runOnUiThread { networkEventSink?.success(true) }
                    TradingForegroundService.notifyNetworkTransition(true)
                }

                override fun onLost(network: Network) {
                    val stillConnected = isNetworkConnected()
                    runOnUiThread { networkEventSink?.success(stillConnected) }
                    TradingForegroundService.notifyNetworkTransition(stillConnected)
                }
            }
            networkCallback = cb
            cm.registerDefaultNetworkCallback(cb)
        } catch (_: Exception) {
        }
    }

    private fun unregisterNetworkCallback() {
        try {
            val cb = networkCallback ?: return
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.unregisterNetworkCallback(cb)
            networkCallback = null
        } catch (_: Exception) {
        }
    }
}
