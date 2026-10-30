package io.github.anmirror.phone

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The licence texts ship inside the APK (assets/licenses, ruling R41). NOTICE there is the repository's NOTICE,
 * every bundled component is named in it, and every licence it relies on has its text.
 */
class LicenseAssetsTest {
    private val dir = File(System.getProperty("anmirror.licenses") ?: "src/main/assets/licenses")
    private val notice by lazy { File(dir, "NOTICE").readText() }

    /** File name -> words its licence text must contain. */
    private val texts = mapOf(
        "Apache-2.0.txt" to listOf("Apache License", "Version 2.0, January 2004"),
        "BSD-3-Clause.txt" to listOf("Redistributions in binary form must reproduce", "Neither the name of"),
        "MIT.txt" to listOf("Permission is hereby granted, free of charge"),
        "ISC.txt" to listOf("Permission to use, copy, modify, and/or distribute this software"),
        "LGPL-2.1.txt" to listOf("GNU LESSER GENERAL PUBLIC LICENSE", "Version 2.1, February 1999"),
        "LGPL-3.0.txt" to listOf("GNU LESSER GENERAL PUBLIC LICENSE", "Version 3, 29 June 2007"),
        "GPL-3.0.txt" to listOf("GNU GENERAL PUBLIC LICENSE", "Version 3, 29 June 2007"),
        "BoringSSL.txt" to listOf("OpenSSL License", "Original SSLeay License"),
    )

    /** Shipped outside the runtime classpath, or not yet on it (Full mode's :core:adb joins the app in Task 3). */
    private val alwaysNamed = listOf(
        "scrcpy-server 5.0.1", "libadb-android", "spake2-android", "Conscrypt", "BoringSSL", "Bouncy Castle",
        "GNU C Library", "fiat-crypto",
    )

    /** Maven group:module of each runtime dependency -> the name NOTICE must use for it. */
    private fun noticeName(module: String): String? {
        val (group, name) = module.split(":")
        return when {
            group.startsWith("androidx.compose") -> "Jetpack Compose"
            group.startsWith("androidx.") -> "AndroidX"
            group == "org.jetbrains.kotlin" && name.startsWith("kotlin-stdlib") -> "Kotlin standard library"
            group == "org.jetbrains" && name == "annotations" -> "JetBrains annotations"
            group == "org.jetbrains.kotlinx" && name.startsWith("kotlinx-coroutines") -> "kotlinx.coroutines"
            group == "org.jetbrains.kotlinx" && name.startsWith("kotlinx-serialization") -> "kotlinx.serialization"
            group == "com.google.protobuf" -> "Protocol Buffers"
            group == "com.google.zxing" -> "ZXing core"
            group == "com.journeyapps" -> "ZXing Android Embedded"
            group == "com.google.guava" -> "Guava"
            group == "org.jspecify" -> "JSpecify"
            group == "com.github.MuntashirAkon" && name == "libadb-android" -> "libadb-android"
            group == "com.github.MuntashirAkon.spake2-java" -> "spake2-android"
            group == "org.conscrypt" -> "Conscrypt"
            group == "org.bouncycastle" -> "Bouncy Castle"
            else -> null
        }
    }

    @Test fun licenceTextsAreBundled() {
        for ((file, words) in texts) {
            val f = File(dir, file)
            assertTrue(f.isFile, "missing assets/licenses/$file")
            val text = f.readText()
            for (w in words) assertTrue(text.contains(w), "$file lacks \"$w\"")
            assertTrue(text.contains("Copyright"), "$file has no copyright lines")
        }
    }

    @Test fun bundledNoticeIsTheRepositoryNotice() {
        val repo = File(System.getProperty("anmirror.notice") ?: "../../NOTICE")
        assertEquals(repo.readText(), notice, "assets/licenses/NOTICE differs from the repository NOTICE; copy it again")
    }

    @Test fun noticeNamesEveryBundledComponent() {
        val modules = System.getProperty("anmirror.runtimeModules").orEmpty().split(",").filter { it.isNotEmpty() }
        assertTrue(modules.isNotEmpty(), "the build passes the release runtime classpath as anmirror.runtimeModules")
        val names = modules.map { noticeName(it) ?: fail("$it is shipped but has no NOTICE name; add it to NOTICE and this test") }
        val headers = texts.keys.joinToString("\n") { File(dir, it).readText().substringBefore("=".repeat(78)) }
        for (name in (names + alwaysNamed).toSortedSet()) {
            assertTrue(notice.contains(name), "NOTICE does not name $name")
            assertTrue(headers.contains(name), "no licence file in assets/licenses lists $name")
        }
    }

    @Test fun everyLicenceInNoticeHasItsText() {
        val needs = mapOf(
            "Apache License, Version 2.0" to "Apache-2.0.txt", "BSD 3-Clause License" to "BSD-3-Clause.txt",
            "MIT License" to "MIT.txt", "ISC License" to "ISC.txt", "LGPL v2.1" to "LGPL-2.1.txt",
            "LGPL v3.0" to "LGPL-3.0.txt", "GNU GPL v3" to "GPL-3.0.txt", "OpenSSL License" to "BoringSSL.txt",
        )
        for ((licence, file) in needs) {
            assertTrue(notice.contains(licence), "NOTICE no longer mentions $licence; drop $file from this test")
            assertTrue(File(dir, file).isFile, "NOTICE relies on $licence but assets/licenses/$file is missing")
        }
    }
}
