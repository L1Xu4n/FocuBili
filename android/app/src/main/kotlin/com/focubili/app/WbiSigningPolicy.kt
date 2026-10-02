package com.focubili.app

import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest

/** WBI 的纯签名规则；与 Dart 使用相同的排序、清洗、编码和置换表。 */
internal object WbiSigningPolicy {
    private val keyOrder = intArrayOf(
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    )
    private val keyPattern = Regex("^[0-9a-fA-F]{32}$")
    private val filteredCharacters = Regex("[!'()*]")
    const val UNAVAILABLE_MESSAGE =
        "WBI 签名材料暂时无法获取，请稍后重试，或在“播放与专注”中关闭“启用 WBI 签名”。"

    /** 验证材料长度与内容，按固定置换表生成 32 位混合键。 */
    fun deriveMixinKey(imageKey: String, subKey: String): String {
        require(keyPattern.matches(imageKey) && keyPattern.matches(subKey))
        val combined = imageKey + subKey
        return keyOrder.map { combined[it] }.joinToString("")
    }

    /** 覆盖旧签名、过滤值中的特殊字符，用当前秒级时间戳生成新的摘要。 */
    fun sign(parameters: Map<String, String>, mixinKey: String, timestamp: Long): Map<String, String> {
        require(keyPattern.matches(mixinKey))
        val result = parameters.filterKeys { it != "wts" && it != "w_rid" }
            .mapValues { it.value.replace(filteredCharacters, "") }.toMutableMap()
        result["wts"] = timestamp.toString()
        val digest = MessageDigest.getInstance("MD5")
            .digest((encodeQuery(result) + mixinKey).toByteArray(Charsets.UTF_8))
        result["w_rid"] = digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        return result
    }

    /** 使用与浏览器 encodeURIComponent 一致的编码，空格采用 %20。 */
    private fun encodeComponent(value: String): String =
        URLEncoder.encode(value, "UTF-8").replace("+", "%20").replace("%7E", "~")

    /** 对参数排序后编码，供签名计算与实际 HTTPS 请求共同使用。 */
    fun encodeQuery(parameters: Map<String, String>): String =
        parameters.toSortedMap().entries.joinToString("&") {
            "${encodeComponent(it.key)}=${encodeComponent(it.value)}"
        }
}

/** 只在内存保存一小时签名材料；不保存 Cookie，也不下载材料图片。 */
internal class PlaybackWbiSigner(
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private var cachedKey: String? = null
    private var cachedAt = 0L

    /** 通过注入的固定官方 nav 请求获取材料；每次播放都生成新时间戳。 */
    @Synchronized
    fun sign(parameters: Map<String, String>, requestNavigation: () -> String): Map<String, String> {
        val age = clock() - cachedAt
        val key = cachedKey?.takeIf { age in 0L until 3_600_000L } ?: run {
            val root = JSONObject(requestNavigation())
            // 游客 nav 的 code 可为 -101，wbi_img 材料仍有效，不要求登录。
            val images = root.getJSONObject("data").getJSONObject("wbi_img")
            WbiSigningPolicy.deriveMixinKey(
                keyFromUrl(images.getString("img_url")),
                keyFromUrl(images.getString("sub_url")),
            ).also {
                cachedKey = it
                cachedAt = clock()
            }
        }
        return WbiSigningPolicy.sign(parameters, key, clock() / 1000L)
    }

    /** 只解析服务器材料 URL 的文件名，绝不将它作为额外网络目标。 */
    private fun keyFromUrl(value: String): String =
        URI(value).path.substringAfterLast('/').substringBefore('.')
}
