plugins {
    alias(libs.plugins.android.library)
}

// The phone's own Wireless debugging client (Full mode): its identity, pairing, connection and
// streams over libadb-android, and the NSD lookup of the daemon's ports.
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
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)
}
