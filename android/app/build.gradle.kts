plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "io.github.anmirror.phone"

    compileSdk {
        version = release(libs.versions.androidCompileSdk.get().toInt()) {
            minorApiLevel = libs.versions.androidCompileSdkMinor.get().toInt()
        }
    }

    defaultConfig {
        applicationId = "io.github.anmirror.phone"
        minSdk = libs.versions.androidMinSdk.get().toInt()
        targetSdk = libs.versions.androidTargetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0"
    }

    // One flavor today (GitHub and F-Droid). A later `play` flavor can drop Play-restricted
    // permissions from its manifest (ARCHITECTURE §5).
    flavorDimensions += "distribution"
    productFlavors {
        create("oss") {
            dimension = "distribution"
            // READ_CALL_LOG and ANSWER_PHONE_CALLS are declared in src/oss only. `-PplayLike=true`
            // turns both switches off, to check that a build without them still works.
            val playLike = providers.gradleProperty("playLike").orNull == "true"
            buildConfigField("boolean", "FEATURE_CALL_LOG", (!playLike).toString())
            buildConfigField("boolean", "FEATURE_ANSWER_CALLS", (!playLike).toString())
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        val jvmTarget = JavaVersion.toVersion(libs.versions.jvmTarget.get())
        sourceCompatibility = jvmTarget
        targetCompatibility = jvmTarget
    }

    testOptions {
        // android.util.Log in plain JVM unit tests: return defaults instead of throwing.
        unitTests.isReturnDefaultValues = true
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(project(":core:connection"))
    implementation(project(":feature:status"))
    implementation(project(":feature:find"))
    implementation(project(":feature:notify"))
    implementation(project(":feature:contacts"))
    implementation(project(":feature:calls"))
    implementation(project(":feature:clipboard"))
    implementation(project(":feature:share"))
    implementation(project(":feature:screenshots"))
    implementation(project(":core:transfer"))
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.service)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    debugImplementation(platform(libs.androidx.compose.bom))
    debugImplementation(libs.androidx.compose.ui.tooling)

    // QR scanning without Play Services or ML Kit (F-Droid).
    implementation(libs.zxing.android.embedded)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
