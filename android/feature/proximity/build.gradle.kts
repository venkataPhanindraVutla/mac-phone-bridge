plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "io.github.anmirror.feature.proximity"

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
    // PairingCrypto.bleId / epochOf / BLE_SERVICE_UUID (SPEC 22).
    api(project(":core:protocol"))
    // PairedMac: the discovery key and lastConnectedAt.
    api(project(":core:connection"))
    api(libs.kotlinx.coroutines.core)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
