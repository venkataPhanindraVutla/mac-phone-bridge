package io.github.anmirror.phone

import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals

/** Full mode's components in the main manifest: who may reach them. */
class ManifestTest {
    private val android = "http://schemas.android.com/apk/res/android"

    private fun component(tag: String, name: String): Element {
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val nodes = doc.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }.single { it.getAttributeNS(android, "name") == name }
    }

    @Test
    fun delayTestScreenIsForTheShellOnly() {
        // Ruling R52: `am start` runs as the shell, which can't start a non-exported activity;
        // DUMP is the shell's and is never granted to another app.
        val activity = component("activity", ".mirror.DelayTestActivity")
        assertEquals("true", activity.getAttributeNS(android, "exported"))
        assertEquals("android.permission.DUMP", activity.getAttributeNS(android, "permission"))
    }

    @Test
    fun mirrorStopReceiverIsPrivate() {
        assertEquals("false", component("receiver", ".service.MirrorStopReceiver").getAttributeNS(android, "exported"))
    }
}
