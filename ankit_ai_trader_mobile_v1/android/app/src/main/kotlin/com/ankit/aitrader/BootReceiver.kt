package com.ankit.aitrader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val act = intent.action ?: return
        if (act == Intent.ACTION_BOOT_COMPLETED ||
            act == "android.intent.action.QUICKBOOT_POWERON" ||
            act == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            val prefs = context.getSharedPreferences("AnkitPrefs", Context.MODE_PRIVATE)
            val engineState = prefs.getString("engine_state", "STOPPED")
            if (engineState == "RUNNING") {
                try {
                    val serviceIntent = Intent(context, TradingForegroundService::class.java).apply {
                        action = TradingForegroundService.ACTION_START
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(serviceIntent)
                    } else {
                        context.startService(serviceIntent)
                    }
                } catch (_: Exception) {
                }
            }
        }
    }
}
