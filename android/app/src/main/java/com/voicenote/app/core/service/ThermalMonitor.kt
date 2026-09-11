package com.voicenote.app.core.service

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.util.Log

/**
 * 设备热状态监控器，从 [RecordingService] 中抽离。
 * 当设备过热时发出一次性告警。
 */
class ThermalMonitor(private val context: Context) {
    private var warningShown = false

    companion object { private const val TAG = "ThermalMonitor" }

    /** 检查热状态，返回告警消息、通知消息各一条（null = 无需告警） */
    @SuppressLint("NewApi")
    fun check(statusCallback: (String?) -> Unit, notificationCallback: (String?) -> Unit) {
        if (warningShown) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return

        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val status = pm.currentThermalStatus
        if (status >= PowerManager.THERMAL_STATUS_SEVERE) {
            warningShown = true
            Log.w(TAG, "设备过热 (thermal=$status)，建议结束录音")
            statusCallback("⚠️ 设备过热，建议结束录音")
            notificationCallback("⚠️ 设备过热，建议结束录音")
        }
    }
}