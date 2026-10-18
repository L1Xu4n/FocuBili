package com.focubili.app

/** 不依赖 Android 的最终通知授权谓词，前台和后台共用同一份持久化开关。 */
object SubscriptionNotificationGenerationPolicy {
    fun isAllowed(
        enabled: Boolean,
        notificationsEnabled: Boolean,
        backgroundRefreshEnabled: Boolean,
        storedGeneration: Long?,
        expectedGeneration: Long,
        background: Boolean,
    ): Boolean {
        return enabled && notificationsEnabled &&
            expectedGeneration >= 0 && storedGeneration == expectedGeneration &&
            (!background || backgroundRefreshEnabled)
    }
}
