package io.github.anmirror.transfer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FileNamesTest {
    private val vectors: JsonObject = Json.parseToJsonElement(
        File(checkNotNull(System.getProperty("anmirror.vectors")), "filenames.json").readText(),
    ).jsonObject

    @Test
    fun sanitizeMatchesVectors() {
        val cases = vectors.getValue("sanitize").jsonArray
        assertTrue(cases.size > 10)
        for (c in cases) {
            val o = c.jsonObject
            val out = FileNames.sanitize(o.getValue("in").jsonPrimitive.content)
            assertEquals(o.getValue("out").jsonPrimitive.content, out)
            assertTrue(out.toByteArray().size <= 255)
        }
    }

    @Test
    fun uniqueAddsCounterWithinCap() {
        val cases: JsonArray = vectors.getValue("unique").jsonArray
        assertTrue(cases.size > 5)
        for (c in cases) {
            val o = c.jsonObject
            val taken = o.getValue("taken").jsonArray.map { it.jsonPrimitive.content }.map(FileNames::key).toSet()
            val out = FileNames.unique(o.getValue("name").jsonPrimitive.content) { FileNames.key(it) in taken }
            assertEquals(o.getValue("out").jsonPrimitive.content, out)
            assertTrue(out.toByteArray().size <= 255)
        }
    }
}
