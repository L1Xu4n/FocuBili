package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** 验证原生签名与 Dart 的固定向量一致，防止两端编码差异。 */
class WbiSigningPolicyTest {
    /** 使用 Python hashlib 独立计算的固定向量，不依赖 Android 或网络。 */
    @Test
    fun knownSigningVector() {
        val key = WbiSigningPolicy.deriveMixinKey(
            "7cd084941338484aae1ad9425b84077c", "4932caff0ff746eab6f01bf08b70ac45",
        )
        assertEquals("ea1db124af3c7062474693fa704f4ff8", key)
        val signed = WbiSigningPolicy.sign(
            mapOf("foo" to "114", "bar" to "514", "baz" to "1919810"), key, 1702204169L,
        )
        assertEquals("6149fdadf571698ca7e6a567265cd0ee", signed["w_rid"])
    }

    /** 覆盖特殊字符、中文及空格，确保发送参数与规范签名串一致。 */
    @Test
    fun sanitizedQueryUsesPercentEncoding() {
        val signed = WbiSigningPolicy.sign(
            mapOf("z" to "a!b'()* 中文", "wts" to "1", "w_rid" to "stale"),
            "ea1db124af3c7062474693fa704f4ff8", 123L,
        )
        assertEquals("ab 中文", signed["z"])
        assertEquals("123", signed["wts"])
        assertFalse(signed["w_rid"] == "stale")
        assertEquals("a=1&z=ab%20%E4%B8%AD%E6%96%87",
            WbiSigningPolicy.encodeQuery(mapOf("z" to signed.getValue("z"), "a" to "1")))
    }

    /** 材料长度异常必须失败，不能使用空键构造看似有效的签名。 */
    @Test(expected = IllegalArgumentException::class)
    fun invalidMaterialIsRejected() {
        WbiSigningPolicy.deriveMixinKey("short", "4932caff0ff746eab6f01bf08b70ac45")
    }
}
