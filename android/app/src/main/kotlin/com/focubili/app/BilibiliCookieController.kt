package com.focubili.app

import android.webkit.CookieManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * 管理本应用 WebView 的 B 站 Cookie，使官方网页登录、Cookie 登录和原生播放共享会话。
 *
 * Cookie 只保存在 Android WebView 的应用沙箱中，不写入日志或 Flutter 本地偏好设置。
 */
class BilibiliCookieController(
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val cookieManager = CookieManager.getInstance()

    /** 创建控制器时启用 WebView Cookie，并注册 Flutter 方法通道。 */
    init {
        cookieManager.setAcceptCookie(true)
        channel.setMethodCallHandler(this)
    }

    /** 接收读取、写入和清除 B 站会话的 Flutter 请求。 */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readCookies" -> result.success(readBilibiliCookies())
            "setCookies" -> {
                val rawCookie = call.argument<String>("cookie").orEmpty()
                val cookies = parseCookiePairs(rawCookie)
                if (cookies.none { cookie -> cookie.first.equals("SESSDATA", true) }) {
                    result.error("missing_session", "Cookie 中没有找到 SESSDATA。", null)
                    return
                }
                writeBilibiliCookies(cookies, result)
            }
            "clearCookies" -> clearCookies(result)
            else -> result.notImplemented()
        }
    }

    /** 从 B 站常用子域读取 Cookie，并按名称去重后组合为标准请求头。 */
    private fun readBilibiliCookies(): String {
        val valuesByName = linkedMapOf<String, String>()
        BILIBILI_COOKIE_URLS.forEach { url ->
            cookieManager.getCookie(url)
                .orEmpty()
                .split(';')
                .mapNotNull(::parseCookiePair)
                .forEach { cookie -> valuesByName[cookie.first] = cookie.second }
        }
        return valuesByName.entries.joinToString("; ") { entry ->
            "${entry.key}=${entry.value}"
        }
    }

    /** 将用户粘贴的 Cookie 文本拆成合法名称和值，并忽略 Domain 等属性字段。 */
    private fun parseCookiePairs(rawCookie: String): List<Pair<String, String>> {
        return rawCookie
            .replace('\n', ';')
            .replace('\r', ';')
            .split(';')
            .mapNotNull(::parseCookiePair)
            .filterNot { cookie ->
                RESERVED_COOKIE_ATTRIBUTES.contains(cookie.first.lowercase(Locale.ROOT))
            }
    }

    /** 把单个“名称=值”片段转换为键值对，拒绝非法名称、空值和控制字符。 */
    private fun parseCookiePair(rawPart: String): Pair<String, String>? {
        val part = rawPart.trim()
        val separatorIndex = part.indexOf('=')
        if (separatorIndex <= 0 || separatorIndex >= part.lastIndex) {
            return null
        }
        val name = part.substring(0, separatorIndex).trim()
        val value = part.substring(separatorIndex + 1).trim()
        if (!COOKIE_NAME_PATTERN.matches(name) ||
            value.isEmpty() ||
            value.any { character -> character.code < 0x20 }
        ) {
            return null
        }
        return name to value
    }

    /** 将合法 Cookie 异步写入固定的 B 站根域，全部完成后再通知 Flutter 验证账号。 */
    private fun writeBilibiliCookies(
        cookies: List<Pair<String, String>>,
        result: MethodChannel.Result,
    ) {
        var remainingCount = cookies.size
        var writeFailed = false
        cookies.forEach { cookie ->
            cookieManager.setCookie(
                BILIBILI_ROOT_URL,
                "${cookie.first}=${cookie.second}; Domain=.bilibili.com; Path=/; Secure",
            ) { accepted ->
                writeFailed = writeFailed || !accepted
                remainingCount -= 1
                if (remainingCount == 0) {
                    cookieManager.flush()
                    if (writeFailed) {
                        result.error("cookie_write_failed", "部分 Cookie 无法写入。", null)
                    } else {
                        result.success(null)
                    }
                }
            }
        }
    }

    /** 清除本应用 WebView 的全部 Cookie，并在异步操作完成后通知 Flutter。 */
    private fun clearCookies(result: MethodChannel.Result) {
        cookieManager.removeAllCookies {
            cookieManager.flush()
            result.success(null)
        }
    }

    /** Activity 销毁时注销方法通道，避免 Flutter 引擎释放后仍接收调用。 */
    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val CHANNEL_NAME = "com.focubili.app/auth"
        private const val BILIBILI_ROOT_URL = "https://www.bilibili.com"
        private val BILIBILI_COOKIE_URLS = listOf(
            BILIBILI_ROOT_URL,
            "https://api.bilibili.com",
            "https://passport.bilibili.com",
        )
        private val COOKIE_NAME_PATTERN = Regex("^[A-Za-z0-9_]+$")
        private val RESERVED_COOKIE_ATTRIBUTES = setOf(
            "domain",
            "path",
            "expires",
            "max-age",
            "samesite",
            "secure",
            "httponly",
        )
    }
}
