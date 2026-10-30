plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "io.github.anmirror.feature.dnd"

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
    api(project(":core:protocol"))
    api(libs.kotlinx.coroutines.core)
    // DndOverride / AndroidDndOverride: the interruption filter, shared with Find my phone.
    api(project(":feature:find"))

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
