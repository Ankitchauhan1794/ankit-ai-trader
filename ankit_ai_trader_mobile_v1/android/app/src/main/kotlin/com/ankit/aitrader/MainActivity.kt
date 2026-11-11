package com.ankit.aitrader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.ankit.aitrader/background_engine"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    startTradingService()
                    result.success(true)
                }
                "stopService" -> {
                    stopTradingService()
                    result.success(true)
                }
                "isServiceRunning" -> {
                    val prefs = getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
                    val state = prefs.getString("engine_state", "STOPPED")
                    result.success(state == "RUNNING")
                }
                "requestBatteryOptimizations" -> {
                    requestDisableBatteryOptimization()
                    result.success(true)
                }
                "isBatteryOptimizationDisabled" -> {
                    result.success(isBatteryOptimizationDisabled())
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startTradingService() {
        val serviceIntent = Intent(this, TradingForegroundService::class.java).apply {
            action = TradingForegroundService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun stopTradingService() {
        val serviceIntent = Intent(this, TradingForegroundService::class.java).apply {
            action = TradingForegroundService.ACTION_STOP
        }
        startService(serviceIntent)
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
            if (!isBatteryOptimizationDisabled()) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            }
        }
    }
}
