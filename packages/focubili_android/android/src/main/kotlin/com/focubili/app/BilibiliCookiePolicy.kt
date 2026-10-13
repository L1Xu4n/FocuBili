package com.focubili.app

/** 不可将同名 Cookie 的逐字段覆盖当作同一账号会话。所有返回值只在内存使用。 */
object BilibiliCookiePolicy {
    // 优先使用播放 API 自身的完整快照；绝不从其他域补齐其缺失字段。
    val urls = listOf("https://api.bilibili.com", "https://www.bilibili.com", "https://passport.bilibili.com")
    private val identityNames = setOf("SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5")
    private val namePattern = Regex("^[A-Za-z0-9_]+$")

    enum class State { SESSION, ANONYMOUS, UNKNOWN, CONFLICT, CHANGING }
    class Snapshot(
        val state: State,
        val header: String = "",
        val partial: Boolean = false,
        internal val identity: String? = null,
        val generation: Long = 0L,
    )
    class Unavailable(val state: State) : IllegalStateException(when (state) {
        State.CONFLICT -> "不同域的登录会话存在冲突，请到“我的”重新登录。"
        State.CHANGING -> "登录状态正在切换，请稍后重试。"
        else -> "暂时无法读取登录会话，可重试或仅以游客播放本次视频。"
    })

    /** 每个域单独读取；部分失败仅信任请求目标 API 域自身的完整快照。 */
    fun inspect(readCookie: (String) -> String?): Snapshot {
        val snapshots = mutableListOf<LinkedHashMap<String, String>>()
        var failures = 0
        var conflict = false
        var apiSnapshot: LinkedHashMap<String, String>? = null
        urls.forEach { url ->
            try {
                val values = linkedMapOf<String, String>()
                readCookie(url).orEmpty().split(';').forEach { raw ->
                    val part = raw.trim()
                    val index = part.indexOf('=')
                    if (index > 0 && index < part.lastIndex) {
                        val name = part.substring(0, index).trim()
                        val value = part.substring(index + 1).trim()
                        if (namePattern.matches(name) && value.isNotEmpty() && value.none { it.code < 0x20 }) {
                            if (name in identityNames && values[name]?.let { it != value } == true) conflict = true
                            values[name] = value
                        }
                    }
                }
                snapshots.add(values)
                if (url == urls.first()) apiSnapshot = values
            } catch (_: Exception) { failures++ }
              catch (_: LinkageError) { failures++ }
        }
        identityNames.forEach { name ->
            if (snapshots.mapNotNull { it[name] }.distinct().size > 1) conflict = true
        }
        if (conflict) return Snapshot(State.CONFLICT, partial = failures > 0)
        val selected = if (failures > 0) apiSnapshot?.takeIf { !it["SESSDATA"].isNullOrBlank() }
            else snapshots.firstOrNull { !it["SESSDATA"].isNullOrBlank() }
        if (selected != null) return Snapshot(
            State.SESSION,
            selected.entries.joinToString("; ") { "${it.key}=${it.value}" },
            failures > 0,
            selected["SESSDATA"],
        )
        return Snapshot(if (failures > 0) State.UNKNOWN else State.ANONYMOUS, partial = failures in 1..2)
    }

    fun readHeader(readCookie: (String) -> String?): String {
        val snapshot = inspect(readCookie)
        if (snapshot.state != State.SESSION && snapshot.state != State.ANONYMOUS) throw Unavailable(snapshot.state)
        return snapshot.header
    }

    /** 清理独立收集所有名称，冲突不能阻止用户主动退出或切换账号。 */
    fun namesForClear(readCookie: (String) -> String?): Set<String> {
        val names = identityNames.toMutableSet()
        urls.forEach { url ->
            val header = try { readCookie(url) }
                catch (_: Exception) { null }
                catch (_: LinkageError) { null }
            header.orEmpty().split(';').forEach {
                val name = it.substringBefore('=').trim()
                if (namePattern.matches(name)) names.add(name)
            }
        }
        return names
    }

    fun hasSession(header: String): Boolean =
        Regex("(^|;\\s*)SESSDATA=([^;]+)").containsMatchIn(header)
}

/** 登录写入与播放请求共用代次，不保存凭据到磁盘；切换过程中不暴露半写入快照。 */
object BilibiliSessionGate {
    private var revision = 0L
    private var writing = false
    private var lastState: BilibiliCookiePolicy.State? = null
    private var identity: String? = null

    @Synchronized fun generation(): Long = revision
    @Synchronized fun isCurrent(value: Long): Boolean = !writing && value == revision
    @Synchronized fun beginWrite(): Boolean {
        if (writing) return false
        writing = true
        revision++
        return true
    }
    @Synchronized fun endWrite() { writing = false; lastState = null; identity = null; revision++ }

    /** 网络返回后重新观察 WebView，防止未经本控制器写入的账号变化漏过代次检查。 */
    fun validateResponse(generation: Long, readCookie: (String) -> String?): Boolean =
        read(readCookie).generation == generation && isCurrent(generation)

    fun read(readCookie: (String) -> String?): BilibiliCookiePolicy.Snapshot {
        val start = generation()
        if (!isCurrent(start)) return BilibiliCookiePolicy.Snapshot(BilibiliCookiePolicy.State.CHANGING, generation = start)
        val snapshot = BilibiliCookiePolicy.inspect(readCookie)
        return synchronized(this) {
            if (!isCurrent(start)) return@synchronized BilibiliCookiePolicy.Snapshot(BilibiliCookiePolicy.State.CHANGING, generation = revision)
            if (lastState != null && (lastState != snapshot.state || identity != snapshot.identity)) revision++
            lastState = snapshot.state
            identity = snapshot.identity
            BilibiliCookiePolicy.Snapshot(snapshot.state, snapshot.header, snapshot.partial, snapshot.identity, revision)
        }
    }
}
