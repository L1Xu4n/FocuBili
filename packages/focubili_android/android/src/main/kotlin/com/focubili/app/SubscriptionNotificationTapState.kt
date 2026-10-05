package com.focubili.app

/** 保留 Flutter 尚未监听时的通知点击，冷启动和 Activity 重建不会重复投递。 */
class SubscriptionNotificationTapState {
    private var pending = false
    private var listening = false

    /** 返回 true 时已可直接通知 Dart；否则等待 Dart 的首次 consumeTap。 */
    fun capture(): Boolean {
        if (listening) return true
        pending = true
        return false
    }

    /** Dart 先安装监听器再调用本方法，补取且仅补取一次冷启动点击。 */
    fun consume(): Boolean {
        listening = true
        val tapped = pending
        pending = false
        return tapped
    }
}
