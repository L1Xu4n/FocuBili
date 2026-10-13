package com.focubili.app

/** 登录和播放共享同一域合并规则；读取失败交给调用者处理，绝不伪装成游客。 */
internal object BilibiliCookiePolicy {
    val urls = listOf(
        "https://www.bilibili.com",
        "https://api.bilibili.com",
        "https://passport.bilibili.com",
    )
    private val namePattern = Regex("^[A-Za-z0-9_]+$")

    /** 保留已有登录读取顺序：后一个域的同名 Cookie 覆盖前一个域。 */
    fun readValues(readCookie: (String) -> String?): LinkedHashMap<String, String> {
        val values = linkedMapOf<String, String>()
        urls.forEach { url ->
            readCookie(url).orEmpty().split(';').forEach { raw ->
                val part = raw.trim()
                val separator = part.indexOf('=')
                if (separator > 0 && separator < part.lastIndex) {
                    val name = part.substring(0, separator).trim()
                    val value = part.substring(separator + 1).trim()
                    if (namePattern.matches(name) && value.isNotEmpty() &&
                        value.none { it.code < 0x20 }
                    ) {
                        values[name] = value
                    }
                }
            }
        }
        return values
    }

    /** 会话只在内存拼接，调用者不得记录返回值。 */
    fun readHeader(readCookie: (String) -> String?): String =
        readValues(readCookie).entries.joinToString("; ") { "${it.key}=${it.value}" }

    /** 只判断存在性，不把“存在会话标识”误认为已通过服务端鉴权。 */
    fun hasSession(header: String): Boolean =
        Regex("(^|;\\s*)SESSDATA=([^;]+)", RegexOption.IGNORE_CASE).containsMatchIn(header)
}
