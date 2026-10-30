plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "io.github.anmirror.feature.media"

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
    // NotificationMapper.truncateUtf8: the same 256-byte cut as notifications (SPEC 10).
    implementation(project(":feature:notify"))
    implementation(libs.androidx.core.ktx)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
