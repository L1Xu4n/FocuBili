package com.focubili.app

/** 每次 playurl 请求独立持有；只接收布尔、数值和固定枚举，不接收地址、凭据或响应正文。 */
internal class PlaybackRequestDiagnostic(
    private val requestId: Long,
    val wbiEnabled: Boolean,
    val requestedQuality: Int,
) {
    var wbiSigned = false
    var playurlAttempted = false
    var sessionRead = "not_attempted"
    var authState = "unknown"
    var stage = "cookie"
    var returnedQuality: Int? = null
    var selectedQuality: Int? = null
    var apiCode: Int? = null
    var httpStatus: Int? = null

    /** nav 实际执行且明确验证时才标记认证；WBI 材料缓存命中不会伪造验证结果。 */
    fun observeNavigation(code: Int, isLogin: Boolean?) {
        authState = when {
            code == 0 && isLogin == true -> "authenticated"
            code == -101 || (code == 0 && isLogin == false) ->
                if (authState == "anonymous") "anonymous" else "expired"
            else -> authState
        }
    }

    /** 当前实现从不自动回退到无签名接口；失败和成功均保留本次实际执行状态。 */
    fun toMap(succeeded: Boolean): Map<String, Any?> = mapOf(
        "request_id" to requestId,
        "wbi_enabled" to wbiEnabled,
        "wbi_signed" to wbiSigned,
        "wbi_fallback" to false,
        "playurl_attempted" to playurlAttempted,
        "session_read" to sessionRead,
        "auth_state" to authState,
        "requested_quality" to requestedQuality,
        "returned_quality" to returnedQuality,
        "selected_quality" to selectedQuality,
        "stage" to if (succeeded) "complete" else stage,
        "outcome" to when {
            !succeeded -> "error"
            (selectedQuality ?: requestedQuality) < requestedQuality -> "quality_downgrade"
            else -> "success"
        },
        "api_code" to apiCode,
        "http_status" to httpStatus,
    )
}
