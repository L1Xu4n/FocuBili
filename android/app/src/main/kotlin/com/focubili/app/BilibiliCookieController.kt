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
    // 首次会话操作时才加载内核，避免应用启动就阻塞旧设备的主线程。
    private val cookieManager by lazy {
        CookieManager.getInstance().also { it.setAcceptCookie(true) }
    }

    /** 注册会话通道；WebView 内核延迟到实际会话操作时加载。 */
    init {
        channel.setMethodCallHandler(this)
    }

    /** 接收读取、写入和清除 B 站会话的 Flutter 请求。 */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
        when (call.method) {
            "readCookies" -> result.success(readBilibiliCookies())
            "setCookies" -> {
                val rawCookie = call.argument<String>("cookie").orEmpty()
                val cookies = parseCookiePairs(rawCookie)
                if (cookies.none { cookie -> cookie.first == "SESSDATA" }) {
                    result.error("missing_session", "Cookie 中没有找到 SESSDATA。", null)
                    return
                }
                mutate(result) { guarded -> replaceBilibiliCookies(cookies, guarded) }
            }
            "replaceCookies" -> {
                val rawCookie = call.argument<String>("cookie").orEmpty()
                val cookies = parseCookiePairs(rawCookie)
                if (cookies.none { cookie -> cookie.first == "SESSDATA" }) {
                    result.error("missing_session", "Cookie 中没有找到 SESSDATA。", null)
                    return
                }
                mutate(result) { guarded -> replaceBilibiliCookies(cookies, guarded) }
            }
            "clearCookies", "clearBilibiliCookies" -> mutate(result, ::clearBilibiliCookies)
            else -> result.notImplemented()
        }
        } catch (error: BilibiliCookiePolicy.Unavailable) {
            result.error("session_unavailable", error.message, null)
        } catch (_: Exception) {
            result.error("webview_unavailable", "系统 WebView 会话容器暂时不可用。", null)
        } catch (_: LinkageError) {
            result.error("webview_unavailable", "系统 WebView 组件无法加载。", null)
        }
    }

    /** 登录与播放选择同一个完整快照，切换期间拒绝读取半写入会话。 */
    private fun readBilibiliCookies(): String {
        val snapshot = BilibiliSessionGate.read { cookieManager.getCookie(it) }
        if (snapshot.state != BilibiliCookiePolicy.State.SESSION && snapshot.state != BilibiliCookiePolicy.State.ANONYMOUS) {
            throw BilibiliCookiePolicy.Unavailable(snapshot.state)
        }
        return snapshot.header
    }

    /** 会话修改互斥到最后一个原生回调；失败也必须释放写入状态并作废旧请求。 */
    private fun mutate(result: MethodChannel.Result, operation: (MethodChannel.Result) -> Unit) {
        if (!BilibiliSessionGate.beginWrite()) {
            result.error("session_busy", "登录状态正在切换，请稍后重试。", null)
            return
        }
        var completed = false
        val guarded = object : MethodChannel.Result {
            private fun finish(action: () -> Unit) {
                if (completed) return
                completed = true
                BilibiliSessionGate.endWrite()
                action()
            }
            override fun success(value: Any?) = finish { result.success(value) }
            override fun error(code: String, message: String?, details: Any?) = finish { result.error(code, message, details) }
            override fun notImplemented() = finish { result.notImplemented() }
        }
        try { operation(guarded) }
        catch (_: Exception) { guarded.error("cookie_write_failed", "无法修改登录会话，请稍后重试。", null) }
        catch (_: LinkageError) { guarded.error("webview_unavailable", "系统 WebView 无法加载。", null) }
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
        BilibiliCookieWrites.apply(
            cookies.map { (name, value) -> BILIBILI_ROOT_URL to "$name=$value; Domain=.bilibili.com; Path=/; Secure" },
            { url, value, done -> cookieManager.setCookie(url, value) { done(it) } },
            { cookieManager.flush() },
        ) { success ->
            if (success) result.success(null)
            else result.error("cookie_write_failed", "部分 Cookie 无法写入。", null)
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
                try { writeBilibiliCookies(cookies, result) }
                catch (_: Exception) { result.error("cookie_write_failed", "无法保存登录会话，请重试。", null) }
                catch (_: LinkageError) { result.error("webview_unavailable", "系统 WebView 无法加载。", null) }
            }
        }
    }

    /** 仅清除本应用 WebView 中 B 站域 Cookie，并在异步操作完成后通知 Flutter。 */
    private fun clearBilibiliCookies(result: MethodChannel.Result) {
        clearBilibiliCookies { cleared ->
            if (cleared) {
                result.success(null)
            } else {
                result.error("cookie_clear_failed", "B 站 Cookie 无法清除。", null)
            }
        }
    }

    /** 收集当前 B 站 Cookie 名称并逐个过期，避免误删同一 WebView 的其他网站数据。 */
    private fun clearBilibiliCookies(onComplete: (Boolean) -> Unit) {
        expireBilibiliCookies(
            BilibiliCookiePolicy.namesForClear(cookieManager::getCookie),
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
        BilibiliCookieWrites.apply(deleteOperations,
            { url, value, done -> cookieManager.setCookie(url, value) { done(it) } },
            { cookieManager.flush() }, onComplete)
    }

    /** Activity 销毁时注销方法通道，避免 Flutter 引擎释放后仍接收调用。 */
    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val CHANNEL_NAME = "com.focubili.app/auth"
        private const val BILIBILI_ROOT_URL = "https://www.bilibili.com"
        private val BILIBILI_COOKIE_URLS = BilibiliCookiePolicy.urls
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
