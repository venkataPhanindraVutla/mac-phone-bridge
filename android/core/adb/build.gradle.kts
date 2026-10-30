plugins {
    alias(libs.plugins.android.library)
}

// The phone's own Wireless debugging client (Full mode). Only the dependencies for now, so the
// licence audit (docs/licenses.md) sees the real graph; the code comes with Task 3 of 0.5.
android {
    namespace = "io.github.anmirror.core.adb"

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
    // libadb-android is dual GPL-3.0-or-later OR Apache-2.0; used under Apache-2.0.
    implementation(libs.libadb.android) {
        // bcpkix-jdk18on below brings bcprov-jdk18on; two Bouncy Castle providers would clash.
        exclude(group = "org.bouncycastle", module = "bcprov-jdk15to18")
    }
    implementation(libs.conscrypt.android)
    implementation(libs.bouncycastle.bcpkix)

    testImplementation(libs.junit)
}
