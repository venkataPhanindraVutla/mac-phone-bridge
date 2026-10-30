package io.github.anmirror.phone

import android.content.ActivityNotFoundException
import io.github.anmirror.phone.platform.startFirst
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StartFirstTest {
    @Test
    fun fallsThroughToTheFirstThatOpens() {
        val tried = mutableListOf<String>()
        val opened = startFirst(listOf("request", "list", "app-info")) {
            tried += it
            when (it) {
                "request" -> throw ActivityNotFoundException()
                "list" -> throw SecurityException()
            }
        }
        assertTrue(opened)
        assertEquals(listOf("request", "list", "app-info"), tried)
    }

    @Test
    fun noneOpensWithoutCrashing() {
        val tried = mutableListOf<String>()
        val opened = startFirst(listOf("request", "list", "app-info")) {
            tried += it
            if (it == "list") throw SecurityException() else throw ActivityNotFoundException()
        }
        assertFalse(opened)
        assertEquals(listOf("request", "list", "app-info"), tried)
    }

    @Test
    fun stopsAtTheFirstThatOpens() {
        val tried = mutableListOf<String>()
        assertTrue(startFirst(listOf("request", "list", "app-info")) { tried += it })
        assertEquals(listOf("request"), tried)
    }
}
