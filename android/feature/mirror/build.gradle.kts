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

    compileOptions {
        val jvmTarget = JavaVersion.toVersion(libs.versions.jvmTarget.get())
        sourceCompatibility = jvmTarget
        targetCompatibility = jvmTarget
    }
}

dependencies {
    api(project(":core:adb"))
    api(project(":core:protocol"))
    api(libs.kotlinx.coroutines.core)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
