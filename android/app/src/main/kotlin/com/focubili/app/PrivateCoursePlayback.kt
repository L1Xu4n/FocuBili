package com.focubili.app

import java.io.File

/** Local classroom files must never enter the regular file player. */
internal object PrivateCoursePlayback {
    private const val LEGACY_MAX_WINDOW = 24 * 60 * 60 * 1000L

    fun matches(directory: File?, path: String, filename: String): Boolean =
        directory != null && runCatching {
            File(path).canonicalFile == File(directory, filename).absoluteFile
        }.getOrDefault(false)

    fun restricted(root: File, path: String): Boolean = runCatching {
        val canonical = File(path).canonicalFile.path
        canonical == root.canonicalPath || canonical.startsWith(root.canonicalPath + File.separator)
    }.getOrDefault(true)

    fun acceptsWindow(now: Long, checkedAt: Long, kind: String?, until: Long?): Boolean {
        if (checkedAt <= 0L || now < checkedAt) return false
        return when (kind) {
            "legacyReceipt" -> until != null && until > now &&
                until - checkedAt in 1..LEGACY_MAX_WINDOW
            "serverDeadline" -> until != null && until > now
            "explicitLongTerm", "noDeclaredDeadline" -> until == null
            else -> false
        }
    }
}
