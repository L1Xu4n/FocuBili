package com.focubili.app

import java.io.File

/** Local classroom files must never enter the regular file player. */
internal object PrivateCoursePlayback {
    const val MAX_WINDOW = 24 * 60 * 60 * 1000L

    fun matches(directory: File?, path: String, filename: String): Boolean =
        directory != null && runCatching {
            File(path).canonicalFile == File(directory, filename).absoluteFile
        }.getOrDefault(false)

    fun restricted(root: File, path: String): Boolean = runCatching {
        val canonical = File(path).canonicalFile.path
        canonical == root.canonicalPath || canonical.startsWith(root.canonicalPath + File.separator)
    }.getOrDefault(true)

    fun acceptsWindow(now: Long, until: Long): Boolean =
        until > now && until - now in 1..MAX_WINDOW
}
