package com.focubili.app

import java.net.URI
import java.net.URLDecoder

/** 与 Dart 保持相同的线路优选规则，只重排经过媒体域名校验的原始地址。 */
internal object PlaybackRoutePolicy {
    /** 保留全部候选和签名，以稳定排序应用主备、非 PCDN 与镜像优先级。 */
    fun order(urls: List<String>, preference: String, preferNonPcdn: Boolean): List<String> {
        val unique = urls.distinct()
        if (unique.isEmpty()) return emptyList()
        val ordered = if (preference == "backup") unique.drop(1) + unique.first() else unique
        val smart = preference !in setOf("primary", "backup")
        return ordered.sortedBy { url ->
            (if (preferNonPcdn && isPcdn(url)) 2 else 0) +
                (if (smart && !isMirror(url)) 1 else 0)
        }
    }

    /** 结合域名、os 标记与特殊路径识别 PCDN，不把教育网节点当成 PCDN。 */
    fun isPcdn(url: String): Boolean = runCatching {
        val uri = URI(url)
        val host = uri.host.orEmpty().lowercase()
        host.contains(".mcdn.bilivideo.") || host == "szbdyd.com" || host.endsWith(".szbdyd.com") ||
            uri.rawQuery.orEmpty().split('&').any { part ->
                val pair = part.split('=', limit = 2)
                URLDecoder.decode(pair[0], "UTF-8") == "os" &&
                    pair.size == 2 && URLDecoder.decode(pair[1], "UTF-8") == "mcdn"
            } || Regex("^/v\\d+/resource(?:/|$)").containsMatchIn(uri.path.orEmpty())
    }.getOrDefault(false)

    /** 识别已存在的镜像流，并排除调度地址及带 PCDN 标记的伪镜像。 */
    fun isMirror(url: String): Boolean = runCatching {
        val uri = URI(url)
        !isPcdn(url) && uri.path.orEmpty().startsWith("/upgcxcode/") &&
            Regex("^(?:upos-\\w+-(?!302)\\w+|(?:upos|proxy)-tf-[^/]+)\\.(?:bilivideo|akamaized)\\.(?:com|net)$")
                .matches(uri.host.orEmpty().lowercase())
    }.getOrDefault(false)
}
