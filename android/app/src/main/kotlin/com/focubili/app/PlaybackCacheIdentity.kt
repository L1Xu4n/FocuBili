package com.focubili.app

import java.net.URI
import java.security.MessageDigest
import java.util.Locale

/** 固定一条 DASH 表示的字节身份；签名查询参数和 CDN 主机不属于内容身份。 */
internal data class PlaybackCacheRepresentation(
    val id: Int = 0,
    val bandwidth: Long = 0L,
    val codec: String = "",
    val mimeType: String = "",
    val width: Int = 0,
    val height: Int = 0,
    val frameRate: String = "",
    val initialization: String = "",
    val indexRange: String = "",
    val resourceUrl: String = "",
    val hasConflictingMirrorPaths: Boolean = false,
)

/** 按不可变请求身份及实际表示隔离缓存；旧版键自然失效，由原有 LRU 回收。 */
internal object PlaybackCacheIdentity {
    /** 仅在已验证的官方镜像路径唯一时，将 PCDN 与镜像归到同一资源。 */
    fun withResourceUrls(
        representation: PlaybackCacheRepresentation,
        safeUrls: List<String>,
    ): PlaybackCacheRepresentation {
        val mirrors = safeUrls.filter(PlaybackRoutePolicy::isMirror)
            .distinctBy { URI(it).rawPath }
        return representation.copy(
            resourceUrl = mirrors.singleOrNull() ?: safeUrls.firstOrNull().orEmpty(),
            hasConflictingMirrorPaths = mirrors.size > 1,
        )
    }

    /** 视频指纹保留实际清晰度，音频由自身表示定键；路径冲突时使用本次线路。 */
    fun key(
        bvid: String,
        cid: Long,
        quality: Int,
        video: Boolean,
        representation: PlaybackCacheRepresentation,
        selectedUrl: String = representation.resourceUrl,
    ): String {
        // 刷新签名、换 CDN 主机仍复用相同资源；重新转码得到新路径时不复用旧字节。
        val identityUrl = if (representation.hasConflictingMirrorPaths) selectedUrl else representation.resourceUrl
        val resourcePath = runCatching { URI(identityUrl).rawPath }
            .getOrNull().orEmpty()
        val fields = (if (video) listOf(quality.toString()) else emptyList()) + listOf(
            representation.id.toString(),
            representation.bandwidth.toString(),
            representation.codec.trim().lowercase(Locale.ROOT),
            representation.mimeType.trim().lowercase(Locale.ROOT),
            representation.width.toString(), representation.height.toString(),
            representation.frameRate, representation.initialization,
            representation.indexRange, resourcePath,
        )
        val fingerprint = fields.joinToString("") { "${it.length}:$it" }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(fingerprint.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val type = if (video) "video" else "audio"
        return "focubili-media-v3:${bvid.trim()}:$cid:$type:$digest"
    }
}
