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
    fun adbProofReceiverIsForTheShellOnly() {
        // Ruling R58: `am broadcast` over a new ADB connection reaches it only when the peer really
        // runs commands as the shell; no other app holds DUMP, so an impostor adbd can't send it.
        val receiver = component("receiver", ".full.AdbProofReceiver")
        assertEquals("true", receiver.getAttributeNS(android, "exported"))
        assertEquals("android.permission.DUMP", receiver.getAttributeNS(android, "permission"))
        assertEquals(0, receiver.getElementsByTagName("intent-filter").length, "reached by its explicit name only")
    }

    @Test
    fun shareTargetSurvivesTheUserLeavingWhileFilesOpen() {
        // noHistory would destroy it on leaving and silently drop a slow share (it now says "not sent").
        val activity = component("activity", ".share.ShareToMacActivity")
        assertEquals("", activity.getAttributeNS(android, "noHistory"))
    }

    @Test
    fun mirrorStopReceiverIsPrivate() {
        assertEquals("false", component("receiver", ".service.MirrorStopReceiver").getAttributeNS(android, "exported"))
    }
}
