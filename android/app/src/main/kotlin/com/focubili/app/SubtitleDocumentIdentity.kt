package com.focubili.app

import java.net.URI
import java.security.MessageDigest

/** Identifies an already validated CDN document without exposing its URL or signature. */
internal object SubtitleDocumentIdentity {
    fun key(url: String, language: String): String {
        val path = URI(url).rawPath.orEmpty()
        val fields = listOf(path, language)
        val fingerprint = fields.joinToString("") { "${it.length}:$it" }
        return hash(fingerprint)
    }

    fun hash(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
