package com.voicenote.app.core.common

/** 通用时间格式化工具 */
object TimeUtil {

    /** 将秒数格式化为 mm:ss 或 h:mm:ss */
    fun formatDuration(seconds: Long): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }
}