package com.ankit.aitrader

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SERVICE_CHANNEL = "com.ankit.aitrader/service"
        private const val NETWORK_EVENTS = "com.ankit.aitrader/network_events"
    }

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var eventSink: EventChannel.EventSink? = null

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
                    val title = call.argument<String>("title") ?: "Ankit AI Trader service active"
                    val text = call.argument<String>("text")
                        ?: "Paper trading background monitor running."
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
                    result.success(true)
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "Ankit AI Trader"
                    val text = call.argument<String>("text") ?: "Paper mode active"
                    val intent = Intent(this, TradingForegroundService::class.java).apply {
                        action = TradingForegroundService.ACTION_UPDATE
                        putExtra(TradingForegroundService.EXTRA_TITLE, title)
                        putExtra(TradingForegroundService.EXTRA_TEXT, text)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stopService" -> {
                    val intent = Intent(this, TradingForegroundService::class.java)
                    stopService(intent)
                    result.success(true)
                }
                "isServiceRunning" -> {
                    result.success(TradingForegroundService.isRunning)
                }
                "checkNetworkConnected" -> {
                    result.success(isInternetAvailable())
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
                runOnUiThread {
                    eventSink?.success(true)
                }
            }

            override fun onLost(network: Network) {
                runOnUiThread {
                    eventSink?.success(isInternetAvailable())
                }
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities
            ) {
                val validated =
                    networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                        networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
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