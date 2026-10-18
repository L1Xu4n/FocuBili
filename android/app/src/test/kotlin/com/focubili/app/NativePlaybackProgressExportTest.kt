package com.focubili.app

import org.junit.Assert.*
import org.junit.Test
import java.util.Collections

class NativePlaybackProgressExportTest {
    private val bv = "BV1GJ411x7h7"
    private fun fixture(): MutableMap<String, Any> = mutableMapOf(
        "last-part:$bv:cid" to 202L,
        "last-part:$bv:page" to 2,
        "progress:$bv:101:position" to 12000L,
        "progress:$bv:101:duration" to 90000L,
        "progress:$bv:101:updated_at" to 1700000000000L,
        "progress:$bv:202:position" to 24000L,
        "progress:$bv:202:duration" to 120000L,
        "progress:$bv:103:updated_at" to 1700000001000L,
        "last-part:cheese:ss968174948:cid" to 302L,
        "last-part:cheese:ss968174948:page" to 1,
        "progress:cheese:ss968174948:302:position" to 36000L,
        "progress:cheese:ss968174948:302:duration" to 120000L,
    )

    @Test fun projectsEveryPartAndClearedTimestampWithoutMutatingStorage() {
        val values = fixture().apply {
            put("cookie", "SYNTHETIC_PRIVATE_DO_NOT_EXPORT")
            put("unrelated", setOf("SYNTHETIC_PRIVATE_DO_NOT_EXPORT"))
        }
        val before = values.toMap()
        val exported = NativePlaybackProgressExport.read(Collections.unmodifiableMap(values))
        assertEquals(before, values)
        assertEquals(setOf("format", "version", "lastParts", "parts"), exported.keys)
        val parts = exported["parts"] as List<*>
        assertEquals(4, parts.size)
        val cleared = parts.map { it as Map<*, *> }.single { it["cid"] == 103L }
        assertEquals(mapOf("bvid" to bv, "cid" to 103L, "savedAtMs" to 1700000001000L), cleared)
        val course = parts.map { it as Map<*, *> }.single { it["cid"] == 302L }
        assertEquals("CHEESE:SS968174948", course["bvid"])
        assertFalse(parts.any { (it as Map<*, *>).containsKey("pageNumber") })
        assertFalse(exported.toString().contains("SYNTHETIC_PRIVATE_DO_NOT_EXPORT"))
    }

    @Test fun emptyStoreAndLastPartWithoutPositionRemainExplicit() {
        assertEquals(emptyList<Any>(), NativePlaybackProgressExport.read(emptyMap<String, Any>())["parts"])
        val exported = NativePlaybackProgressExport.read(mapOf<String, Any>("last-part:$bv:cid" to 101L, "last-part:$bv:page" to 1))
        assertEquals(emptyList<Any>(), exported["parts"])
        assertEquals(listOf(mapOf("bvid" to bv, "cid" to 101L, "pageNumber" to 1)), exported["lastParts"])
    }

    @Test fun legacyZeroPositionWithoutTimestampRemainsAValidPersistedRecord() {
        val exported = NativePlaybackProgressExport.read(mapOf<String, Any>(
            "progress:$bv:101:position" to 0L,
            "progress:$bv:101:duration" to 90000L,
        ))
        assertEquals(listOf(mapOf("bvid" to bv, "cid" to 101L, "positionMs" to 0L, "durationMs" to 90000L)), exported["parts"])
    }

    @Test fun historicallyAllowedBvPrefixesCoexistWithoutChangingIdentityCase() {
        val ids = listOf("BV", "Bv", "bV", "bv").map { it + "1gJ411X7h7" }
        val values = mutableMapOf<String, Any>()
        for ((index, id) in ids.withIndex()) {
            values["last-part:$id:cid"] = 101L
            values["last-part:$id:page"] = 1
            values["progress:$id:101:position"] = 12000L + index
            values["progress:$id:101:duration"] = 90000L
        }
        val exported = NativePlaybackProgressExport.read(values)
        val parts = (exported["parts"] as List<*>).map { it as Map<*, *> }
        assertEquals(ids.toSet(), parts.map { it["bvid"] }.toSet())
        assertEquals(4, (exported["lastParts"] as List<*>).size)
        for ((index, id) in ids.withIndex()) {
            assertEquals(12000L + index, parts.single { it["bvid"] == id }["positionMs"])
        }
        for (id in listOf("BX1gJ411X7h7", "VB1gJ411X7h7")) {
            assertThrows(IllegalArgumentException::class.java) {
                NativePlaybackProgressExport.read(mapOf("progress:$id:101:updated_at" to 1L))
            }
        }
    }

    @Test fun unknownProgressFieldsAndMalformedIdentitiesRejectWholeSnapshot() {
        for (key in listOf(
            "progress:$bv:303:url", "progress:$bv:0:updated_at", "progress:$bv:0303:updated_at",
            "progress:https://example.invalid:303:updated_at", "progress:CHEESE:SS0:303:updated_at",
            "progress:cheese:ss999999999999999999999:303:updated_at",
            "progress:$bv:999999999999999999999:updated_at", "last-part:$bv:token",
        )) {
            val values = fixture().apply { put(key, 1L) }
            assertThrows(IllegalArgumentException::class.java) { NativePlaybackProgressExport.read(values) }
        }
    }

    @Test fun wrongTypesAndInvalidValuesRejectWholeSnapshot() {
        val mutations = listOf<Pair<String, Any>>(
            "last-part:$bv:cid" to 0L,
            "last-part:$bv:page" to 0,
            "last-part:$bv:page" to 2L,
            "progress:$bv:101:position" to -1L,
            "progress:$bv:101:position" to 90001L,
            "progress:$bv:101:position" to 12000.0,
            "progress:$bv:101:position" to "12000",
            "progress:$bv:101:duration" to 0L,
            "progress:$bv:101:updated_at" to -1L,
            "progress:$bv:101:updated_at" to 253402300800000L,
        )
        for ((key, value) in mutations) {
            assertThrows(IllegalArgumentException::class.java) {
                NativePlaybackProgressExport.read(fixture().apply { put(key, value) })
            }
        }
    }

    @Test fun incompletePairsRejectRatherThanSilentlyLosingOtherValidParts() {
        for (key in listOf("last-part:$bv:cid", "last-part:$bv:page", "progress:$bv:101:position", "progress:$bv:101:duration")) {
            assertThrows(IllegalArgumentException::class.java) {
                NativePlaybackProgressExport.read(fixture().apply { remove(key) })
            }
        }
    }

    @Test fun conflictingCourseAliasesCannotMergeUnrelatedRows() {
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaybackProgressExport.read(fixture().apply {
                put("progress:CHEESE:SS968174948:404:updated_at", 1700000000000L)
            })
        }
    }
}
