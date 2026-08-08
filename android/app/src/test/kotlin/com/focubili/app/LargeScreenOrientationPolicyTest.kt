package com.focubili.app

import android.content.pm.ActivityInfo
import org.junit.Assert.assertEquals
import org.junit.Test

/** 验证原生冷启动方向断点不会在后续 Android 重构中退化。 */
class LargeScreenOrientationPolicyTest {
    /** 600dp 及以上设备必须请求横屏，覆盖当前 MuMu 平板配置。 */
    @Test
    fun tabletUsesSensorLandscape() {
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE,
            LargeScreenOrientationPolicy.preferredOrientation(600),
        )
    }

    /** 小于 600dp 的普通手机继续保持既有竖屏启动行为。 */
    @Test
    fun phoneUsesPortrait() {
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
            LargeScreenOrientationPolicy.preferredOrientation(599),
        )
    }
}
