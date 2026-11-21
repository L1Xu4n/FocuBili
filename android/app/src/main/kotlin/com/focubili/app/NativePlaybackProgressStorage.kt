package com.focubili.app

import java.io.File
import java.io.StringReader
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.SAXParseException
import org.xml.sax.helpers.DefaultHandler

/** Reads only an already committed preferences file (or its pending-write backup). */
internal object NativePlaybackProgressStorage {
    fun read(main: File): Map<String, Any> {
        val backup = File(main.path + ".bak")
        val selected = when {
            backup.exists() -> backup
            main.exists() -> main
            // Recheck backup after main: a writer may just have renamed main to .bak.
            backup.exists() -> backup
            else -> {
                val directory = requireNotNull(main.parentFile)
                require(!directory.exists() || (directory.isDirectory && directory.canRead()))
                return NativePlaybackProgressExport.read(emptyMap<String, Any>())
            }
        }
        require(selected.isFile && selected.canRead())
        // A file disappearing after selection is an error, never an empty fallback.
        return readXml(selected.readBytes())
    }

    fun readXml(bytes: ByteArray): Map<String, Any> {
        val text = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString().removePrefix("\uFEFF")
        // Before any parser runs, prohibit DTDs, entity declarations/references,
        // including internal expansion and predefined escapes (not used by progress keys).
        require(!text.contains("<!DOCTYPE", ignoreCase = true))
        require(!text.contains("<!ENTITY", ignoreCase = true) && !text.contains('&'))
        val encoding = Regex("encoding\\s*=\\s*['\"]([^'\"]+)['\"]", RegexOption.IGNORE_CASE)
            .find(text.substringBefore("?>"))?.groupValues?.get(1)
        require(encoding == null || encoding.equals("utf-8", ignoreCase = true))
        val handler = PreferencesHandler()
        // No optional JAXP security features: Android API 24 and the host JDK
        // support different feature sets. Reject unsafe syntax before parsing,
        // and independently refuse every external entity resolution callback.
        val parser = SAXParserFactory.newInstance().newSAXParser().xmlReader
        parser.contentHandler = handler
        parser.errorHandler = handler
        parser.entityResolver = handler
        parser.parse(InputSource(StringReader(text)))
        require(handler.finished)
        return NativePlaybackProgressExport.read(handler.values)
    }

    private class PreferencesHandler : DefaultHandler() {
        val values = mutableMapOf<String, Any>()
        var finished = false
        private var depth = 0
        private var type = ""
        private var name = ""
        private var primitive: Any? = null
        private val text = StringBuilder()
        private val strings = mutableSetOf<String>()

        override fun resolveEntity(publicId: String?, systemId: String?): InputSource =
            throw SAXException("External XML resources are not allowed")

        override fun error(error: SAXParseException) { throw error }
        override fun fatalError(error: SAXParseException) { throw error }

        override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
            depth++
            when (depth) {
                1 -> require(qName == "map" && attributes.length == 0)
                2 -> {
                    require(qName in setOf("int", "long", "float", "boolean", "string", "set"))
                    type = qName
                    name = requireNotNull(attributes.getValue("name"))
                    require(!values.containsKey(name))
                    val scalar = type !in setOf("string", "set")
                    require(attributes.length == if (scalar) 2 else 1)
                    primitive = if (scalar) {
                        val value = requireNotNull(attributes.getValue("value"))
                        when (type) {
                            "int" -> requireNotNull(value.toIntOrNull())
                            "long" -> requireNotNull(value.toLongOrNull())
                            "float" -> requireNotNull(value.toFloatOrNull())
                            else -> { require(value == "true" || value == "false"); value == "true" }
                        }
                    } else null
                    text.clear()
                    strings.clear()
                }
                3 -> { require(type == "set" && qName == "string" && attributes.length == 0); text.clear() }
                else -> throw SAXException("Invalid preferences nesting")
            }
        }

        override fun characters(chars: CharArray, start: Int, length: Int) {
            val value = String(chars, start, length)
            if ((depth == 2 && type == "string") || depth == 3) text.append(value)
            else require(value.isBlank())
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            when (depth) {
                3 -> { require(qName == "string"); strings.add(text.toString()); text.clear() }
                2 -> {
                    require(qName == type)
                    values[name] = when (type) {
                        "string" -> text.toString()
                        "set" -> strings.toSet()
                        else -> requireNotNull(primitive)
                    }
                }
                1 -> require(qName == "map")
                else -> throw SAXException("Invalid preferences document")
            }
            depth--
        }

        override fun endDocument() { require(depth == 0); finished = true }
    }
}
