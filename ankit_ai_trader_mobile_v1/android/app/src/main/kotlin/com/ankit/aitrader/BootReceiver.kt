package com.ankit.aitrader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            val prefs = context.getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
            val engineState = prefs.getString("engine_state", "STOPPED")
            if (engineState == "RUNNING") {
                try {
                    val serviceIntent = Intent(context, TradingForegroundService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(serviceIntent)
                    } else {
                        context.startService(serviceIntent)
                    }
                } catch (e: Exception) {
                    // Fallback notification handled or logged
                }
            }
        }
    }
}
