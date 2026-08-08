package com.focubili.app

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 把 Android VIEW Intent 携带的 B站链接安全转交给 Flutter 根组件。 */
internal class DeepLinkController(
    messenger: BinaryMessenger,
    initialLink: String?,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var pendingInitialLink: String? = normalizeLink(initialLink)

    init {
        channel.setMethodCallHandler(::handleMethodCall)
    }

    /** Flutter 冷启动时只能消费一次初始链接，后续读取返回空值。 */
    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getInitialLink") {
            result.notImplemented()
            return
        }
        val link = pendingInitialLink
        pendingInitialLink = null
        result.success(link)
    }

    /** Activity 已运行时把新的外部链接主动推送给 Flutter。 */
    fun handleLink(link: String?) {
        val normalized = normalizeLink(link) ?: return
        channel.invokeMethod("onDeepLink", normalized)
    }

    /** 解除方法处理器，避免 Activity 销毁后通道继续持有旧引用。 */
    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingInitialLink = null
    }

    /** 清理系统传入链接两端空白，空字符串不会进入 Flutter。 */
    private fun normalizeLink(link: String?): String? {
        return link?.trim()?.takeIf(String::isNotEmpty)
    }

    private companion object {
        const val CHANNEL_NAME = "focubili/deep_links"
    }
}
