package com.focubili.app

internal data class CoursePurchaseItem(val id: Long, val expired: Boolean, val unavailable: Boolean)
internal data class CoursePurchasePage(val total: Int, val items: List<CoursePurchaseItem>)
internal class CoursePurchaseException(message: String) : Exception(message)

/** 同一次播放请求必须用同一会话证明目标课程已购；不保留购买清单。 */
internal object CoursePurchaseGate {
    fun verify(seasonId: Long, ensureCurrent: () -> Boolean, loadPage: (Int) -> CoursePurchasePage) {
        val seen = mutableSetOf<Long>()
        var received = 0
        for (page in 1..100) {
            if (!ensureCurrent()) throw CoursePurchaseException("登录状态已变化，请重新打开课程。")
            val result = loadPage(page)
            if (result.total < 0 || result.items.any { it.id <= 0L }) {
                throw CoursePurchaseException("无法确认课程购买状态，请重试。")
            }
            val match = result.items.firstOrNull { it.id == seasonId }
            if (match != null) {
                if (match.expired || match.unavailable) throw CoursePurchaseException("本课程已过期或已下架，请到官方课堂确认。")
                if (!ensureCurrent()) throw CoursePurchaseException("登录状态已变化，请重新打开课程。")
                return
            }
            val previous = seen.size
            seen.addAll(result.items.map { it.id })
            received += result.items.size
            if (received >= result.total) break
            if (seen.size == previous) throw CoursePurchaseException("无法完整确认课程购买状态，请重试。")
        }
        throw CoursePurchaseException("当前账号未购买本课程，或购买资格已失效。")
    }
}
