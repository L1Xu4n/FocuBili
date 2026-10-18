package com.focubili.app

/** 等待所有已提交的写入结束；单次提交抛错不能提前解开账号切换门控。 */
internal object BilibiliCookieWrites {
    fun apply(
        operations: List<Pair<String, String>>,
        write: (String, String, (Boolean) -> Unit) -> Unit,
        flush: () -> Unit,
        onComplete: (Boolean) -> Unit,
    ) {
        val lock = Any()
        val completed = BooleanArray(operations.size)
        var remaining = operations.size
        var failed = false
        fun finish() {
            val flushed = runCatching(flush).isSuccess
            onComplete(!failed && flushed)
        }
        if (operations.isEmpty()) { finish(); return }
        fun complete(index: Int, accepted: Boolean) {
            val allDone = synchronized(lock) {
                if (completed[index]) return
                completed[index] = true
                failed = failed || !accepted
                --remaining == 0
            }
            if (allDone) finish()
        }
        operations.forEachIndexed { index, (url, value) ->
            try { write(url, value) { complete(index, it) } }
            catch (_: Exception) { complete(index, false) }
            catch (_: LinkageError) { complete(index, false) }
        }
    }
}
