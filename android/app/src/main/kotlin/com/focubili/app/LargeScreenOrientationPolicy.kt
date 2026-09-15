package com.focubili.app

import android.content.pm.ActivityInfo

/** 统一决定 Android 手机和平板 Activity 冷启动时应该请求的方向。 */
internal object LargeScreenOrientationPolicy {
    private const val TABLET_SMALLEST_WIDTH_DP = 600

    /** 最短边达到 600dp 时请求传感器横屏，手机保持可旋转的传感器方向。 */
    fun preferredOrientation(smallestScreenWidthDp: Int): Int {
        return if (smallestScreenWidthDp >= TABLET_SMALLEST_WIDTH_DP) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }
}
