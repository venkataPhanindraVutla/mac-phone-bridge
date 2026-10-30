// scrcpy-server v5.0.1, vendored from upstream (see UPSTREAM.md). Translated from upstream's
// server/build.gradle: same plugin, namespace, minSdk and release settings; compileSdk is ours.
// The unsigned release APK is the helper jar the app ships (`:app:copyHelper`).
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.genymobile.scrcpy"

    compileSdk {
        version = release(libs.versions.androidCompileSdk.get().toInt()) {
            minorApiLevel = libs.versions.androidCompileSdkMinor.get().toInt()
        }
    }

    defaultConfig {
        applicationId = "com.genymobile.scrcpy"
        minSdk = 21
        targetSdk = 36
        versionCode = 50001
        // Server.java refuses to start unless the client passes exactly this (BuildConfig.VERSION_NAME).
        versionName = libs.versions.helperVersion.get()
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // Keep the jar (and so BuildConfig.HELPER_SHA256) independent of the checkout's git state.
            vcsInfo.include = false
        }
    }

    buildFeatures {
        buildConfig = true
        aidl = true
    }

    lint {
        disable += "UseRequiresApi"
        // Upstream code: lint findings are reported, never block the build.
        abortOnError = false
        checkReleaseBuilds = false
    }

    testOptions {
        unitTests.all { test ->
            // Shared scrcpy wire fixtures, also used by the Mac tests. Declared as an input so that
            // editing them re-runs the cross-check; the path is passed outside the cache key.
            val vectors = rootProject.file("../protocol/vectors")
            test.inputs.dir(vectors).withPropertyName("scrcpyVectors").withPathSensitivity(PathSensitivity.RELATIVE)
            test.jvmArgumentProviders.add(CommandLineArgumentProvider { listOf("-Danmirror.vectors=${vectors.absolutePath}") })
        }
    }
}

configurations.configureEach {
    // Upstream's sources are pure Java. AGP 9's built-in Kotlin would add kotlin-stdlib (upstream's
    // own release asset carries it), which the server never uses; leaving it out keeps the jar small.
    exclude(group = "org.jetbrains.kotlin", module = "kotlin-stdlib")
}

dependencies {
    testImplementation(libs.junit)
    testImplementation(libs.gson)
}
