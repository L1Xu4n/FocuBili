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
                replaceBilibiliCookies(cookies, result)
            }
            "replaceCookies" -> {
                val rawCookie = call.argument<String>("cookie").orEmpty()
                val cookies = parseCookiePairs(rawCookie)
                if (cookies.none { cookie -> cookie.first.equals("SESSDATA", true) }) {
                    result.error("missing_session", "Cookie 中没有找到 SESSDATA。", null)
                    return
                }
                replaceBilibiliCookies(cookies, result)
            }
            "clearCookies", "clearBilibiliCookies" -> clearBilibiliCookies(result)
            else -> result.notImplemented()
        }
    }

    /** 从 B 站常用子域读取 Cookie，并按名称去重后组合为标准请求头。 */
    private fun readBilibiliCookies(): String {
        return readBilibiliCookieValues().entries.joinToString("; ") { entry ->
            "${entry.key}=${entry.value}"
        }
    }

    /** 汇总 B 站常用子域的 Cookie 名称和值，供读取和仅限 B 站的清理操作复用。 */
    private fun readBilibiliCookieValues(): LinkedHashMap<String, String> {
        val valuesByName = linkedMapOf<String, String>()
        BILIBILI_COOKIE_URLS.forEach { url ->
            cookieManager.getCookie(url)
                .orEmpty()
                .split(';')
                .mapNotNull(::parseCookiePair)
                .forEach { cookie -> valuesByName[cookie.first] = cookie.second }
        }
        return valuesByName
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

    /** 先删除旧 B 站域 Cookie，再写入已通过 Flutter 官方接口验证的新单账号会话。 */
    private fun replaceBilibiliCookies(
        cookies: List<Pair<String, String>>,
        result: MethodChannel.Result,
    ) {
        clearBilibiliCookies { cleared ->
            if (!cleared) {
                result.error("cookie_clear_failed", "旧 B 站 Cookie 无法清除。", null)
            } else {
                writeBilibiliCookies(cookies, result)
            }
        }
    }

    /** 仅清除本应用 WebView 中 B 站域 Cookie，并在异步操作完成后通知 Flutter。 */
    private fun clearBilibiliCookies(result: MethodChannel.Result) {
        clearBilibiliCookies { cleared ->
            if (cleared) {
                cookieManager.flush()
                result.success(null)
            } else {
                result.error("cookie_clear_failed", "B 站 Cookie 无法清除。", null)
            }
        }
    }

    /** 收集当前 B 站 Cookie 名称并逐个过期，避免误删同一 WebView 的其他网站数据。 */
    private fun clearBilibiliCookies(onComplete: (Boolean) -> Unit) {
        expireBilibiliCookies(
            readBilibiliCookieValues().keys,
            onComplete,
        )
    }

    /** 对每个 B 站 Cookie 同时清除主机 Cookie 和根域 Cookie，兼容网页登录产生的两种范围。 */
    private fun expireBilibiliCookies(
        cookieNames: Set<String>,
        onComplete: (Boolean) -> Unit,
    ) {
        val deleteOperations = cookieNames.flatMap { cookieName ->
            BILIBILI_COOKIE_URLS.flatMap { url ->
                listOf(
                    url to "$cookieName=; Max-Age=0; Path=/; Secure",
                    url to "$cookieName=; Max-Age=0; Domain=.bilibili.com; Path=/; Secure",
                )
            }
        }
        if (deleteOperations.isEmpty()) {
            cookieManager.flush()
            onComplete(true)
            return
        }
        var remainingCount = deleteOperations.size
        var deleteFailed = false
        deleteOperations.forEach { operation ->
            cookieManager.setCookie(operation.first, operation.second) { accepted ->
                deleteFailed = deleteFailed || !accepted
                remainingCount -= 1
                if (remainingCount == 0) {
                    cookieManager.flush()
                    onComplete(!deleteFailed)
                }
            }
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
