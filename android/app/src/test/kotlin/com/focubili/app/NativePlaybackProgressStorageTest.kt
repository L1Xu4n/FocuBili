package com.focubili.app

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class NativePlaybackProgressStorageTest {
    private val bv = "BV1GJ411x7h7"
    private fun xml(position: Long = 12000L) = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
        <map>
          <long name="last-part:$bv:cid" value="101" />
          <int name="last-part:$bv:page" value="1" />
          <long name="progress:$bv:101:position" value="$position" />
          <long name="progress:$bv:101:duration" value="90000" />
          <string name="unrelated">SYNTHETIC_DO_NOT_EXPORT</string>
          <set name="unrelated-set"><string>synthetic</string></set>
        </map>""".trimIndent()

    private fun withFiles(block: (File, File) -> Unit) {
        val directory = Files.createTempDirectory("focubili-native-progress-test").toFile()
        val main = File(directory, "progress.xml")
        val backup = File(main.path + ".bak")
        try { block(main, backup) }
        finally { backup.delete(); main.delete(); directory.delete() }
    }

    @Test fun readsCommittedUtf8WithoutEditingFileOrIncludingUnrelatedValues() = withFiles { main, _ ->
        main.writeText(xml())
        val before = main.readBytes()
        val result = NativePlaybackProgressStorage.read(main)
        assertArrayEquals(before, main.readBytes())
        assertEquals(12000L, ((result["parts"] as List<*>).single() as Map<*, *>)["positionMs"])
        assertFalse(result.toString().contains("SYNTHETIC_DO_NOT_EXPORT"))
    }

    @Test fun committedHistoricalBvPrefixCasePassesXmlProjectionUnchanged() {
        for (prefix in listOf("BV", "Bv", "bV", "bv")) {
            val id = prefix + "1gJ411X7h7"
            val result = NativePlaybackProgressStorage.readXml(xml().replace(bv, id).toByteArray())
            assertEquals(id, ((result["lastParts"] as List<*>).single() as Map<*, *>)["bvid"])
            assertEquals(id, ((result["parts"] as List<*>).single() as Map<*, *>)["bvid"])
        }
    }

    @Test fun onlyBothMissingFilesCanRepresentEmptyStorage() = withFiles { main, _ ->
        assertEquals(emptyList<Any>(), NativePlaybackProgressStorage.read(main)["parts"])
        main.writeText("")
        assertThrows(Exception::class.java) { NativePlaybackProgressStorage.read(main) }
        main.delete()
        assertTrue(main.mkdir())
        assertThrows(Exception::class.java) { NativePlaybackProgressStorage.read(main) }
    }

    @Test fun corruptOrUnsupportedXmlNeverBecomesEmptyOrPartialSuccess() {
        for (bad in listOf(
            "<map><long", "<root/>", "<map><long name=\"progress:$bv:1:position\" value=\"broken\"/></map>",
            "<map><unknown name=\"future\" value=\"1\"/></map>",
            "<map><long name=\"progress:$bv:1:updated_at\"/></map>",
            "<map><set name=\"future\"><map/></set></map>",
            "<map><long name=\"same\" value=\"1\"/><long name=\"same\" value=\"2\"/></map>",
            "<map><string name=\"future\">unclosed</map>",
        )) {
            assertThrows(Exception::class.java) { NativePlaybackProgressStorage.readXml(bad.toByteArray()) }
        }
        assertThrows(Exception::class.java) { NativePlaybackProgressStorage.readXml(byteArrayOf(0xc3.toByte(), 0x28)) }
    }

    @Test fun unsafeXmlIsRejectedBeforeParserOrExternalResourceResolution() {
        for (bad in listOf(
            "<!DOCTYPE map SYSTEM 'file:/SYNTHETIC_DO_NOT_READ'><map/>",
            "<!DOCTYPE map [<!ENTITY x SYSTEM 'https://example.invalid/private'>]><map><string name='x'>&x;</string></map>",
            "<map><string name='x'>&amp;</string></map>",
            "<?xml version='1.0' encoding='utf-16'?><map/>",
        )) {
            assertThrows(IllegalArgumentException::class.java) { NativePlaybackProgressStorage.readXml(bad.toByteArray()) }
        }
    }

    @Test fun pendingWriteBackupIsReadWithoutRestorationAndCannotSilentlyFallBack() = withFiles { main, backup ->
        main.writeText("<map><interrupted")
        backup.writeText(xml(15000L))
        val beforeMain = main.readBytes()
        val beforeBackup = backup.readBytes()
        val result = NativePlaybackProgressStorage.read(main)
        assertEquals(15000L, ((result["parts"] as List<*>).single() as Map<*, *>)["positionMs"])
        assertArrayEquals(beforeMain, main.readBytes())
        assertArrayEquals(beforeBackup, backup.readBytes())
        main.delete()
        assertEquals(result, NativePlaybackProgressStorage.read(main))
        main.writeText(xml())
        backup.writeText("<map><interrupted")
        assertThrows(Exception::class.java) { NativePlaybackProgressStorage.read(main) }
    }

    @Test fun selectedFileDisappearingDuringReadFailsInsteadOfReturningEmpty() = withFiles { main, _ ->
        main.writeText(xml())
        val disappearing = object : File(main.path) {
            override fun canRead(): Boolean { main.delete(); return true }
        }
        assertThrows(IOException::class.java) { NativePlaybackProgressStorage.read(disappearing) }
    }
}
