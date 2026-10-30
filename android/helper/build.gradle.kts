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
        versionName = "5.0.1-am1"
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
        unitTests.all {
            // Shared scrcpy wire fixtures, also used by the Mac tests.
            it.systemProperty("anmirror.vectors", rootProject.file("../protocol/vectors").absolutePath)
        }
    }
}

configurations.configureEach {
    // AGP's built-in Kotlin adds kotlin-stdlib to every module. The helper is pure Java, like
    // upstream's jar, and must not carry it.
    exclude(group = "org.jetbrains.kotlin", module = "kotlin-stdlib")
}

dependencies {
    testImplementation(libs.junit)
    testImplementation(libs.gson)
}
