plugins {
    alias(libs.plugins.android.library)
}

// Full mode (F-17): Wireless debugging pairing and connection, and (Task 4) the mirror session.
android {
    namespace = "io.github.anmirror.feature.mirror"

    compileSdk {
        version = release(libs.versions.androidCompileSdk.get().toInt()) {
            minorApiLevel = libs.versions.androidCompileSdkMinor.get().toInt()
        }
    }

    defaultConfig {
        minSdk = libs.versions.androidMinSdk.get().toInt()
    }

    testOptions {
        // The real ADB client (against a loopback socket) calls android.util.Log.
        unitTests.isReturnDefaultValues = true
    }

    compileOptions {
        val jvmTarget = JavaVersion.toVersion(libs.versions.jvmTarget.get())
        sourceCompatibility = jvmTarget
        targetCompatibility = jvmTarget
    }
}

dependencies {
    api(project(":core:adb"))
    // The mirror's bulk links to the Mac (BulkStream, BulkRole).
    api(project(":core:connection"))
    api(project(":core:protocol"))
    api(libs.kotlinx.coroutines.core)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

androidComponents {
    // :core:adb's FakeAdbd (an ADB peer on loopback), for the ADB peer proof through FullModeSetup.
    onVariants { variant ->
        variant.hostTests.values.forEach { it.sources.kotlin?.addStaticSourceDirectory("../../core/adb/src/testShared/kotlin") }
    }
}
