import com.android.build.api.variant.BuildConfigField
import java.security.MessageDigest

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// Full mode's helper: scrcpy-server 5.0.1-am1, built from source by :helper (android/helper/UPSTREAM.md).
// Its unsigned release APK is the jar the app pushes to the phone; the app checks the pushed copy
// against BuildConfig.HELPER_SHA256.
val helperApk = rootProject.layout.projectDirectory.file("helper/build/outputs/apk/release/helper-release-unsigned.apk")
val helperAssets = layout.buildDirectory.dir("generated/helperAssets")
val helperJarFile = helperAssets.map { it.file("anmirror-helper.jar") }
val copyHelper = tasks.register("copyHelper") {
    description = "Copies :helper's unsigned release APK into the app's assets as anmirror-helper.jar."
    dependsOn(":helper:assembleRelease")
    // A declared input file that is missing fails this task with a clear message (a Copy would be NO-SOURCE).
    inputs.file(helperApk).withPropertyName("helperApk").withPathSensitivity(PathSensitivity.NONE)
    outputs.file(helperJarFile).withPropertyName("helperJar")
    val from = helperApk.asFile
    val to = helperJarFile.get().asFile
    doLast { from.copyTo(to, overwrite = true) }
}
val helperJar = copyHelper.map { helperJarFile.get().asFile }

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
        // 5.0.1-am1: the helper's own versionName, from the same catalog entry.
        buildConfigField("String", "HELPER_VERSION", "\"${libs.versions.helperVersion.get()}\"")
    }

    // One flavor today (GitHub and F-Droid). A later `play` flavor can drop Play-restricted
    // permissions from its manifest (ARCHITECTURE §5).
    flavorDimensions += "distribution"
    productFlavors {
        create("oss") {
            dimension = "distribution"
            // READ_CALL_LOG, ANSWER_PHONE_CALLS and MANAGE_EXTERNAL_STORAGE are declared in src/oss
            // only. `-PplayLike=true` turns all three switches off, to check that a build without
            // them still works (browsing then uses picked folders only).
            val playLike = providers.gradleProperty("playLike").orNull == "true"
            buildConfigField("boolean", "FEATURE_CALL_LOG", (!playLike).toString())
            buildConfigField("boolean", "FEATURE_ANSWER_CALLS", (!playLike).toString())
            buildConfigField("boolean", "FEATURE_ALL_FILES", (!playLike).toString())
        }
    }

    sourceSets.getByName("main").assets.directories.add(helperAssets.get().asFile.path)

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

    packaging {
        resources {
            // bcpkix, bcutil and bcprov (Full mode's ADB identity) each carry the same Bouncy Castle
            // licence; one copy ships, and assets/licenses has it too.
            pickFirsts += "META-INF/LICENSE.md"
        }
    }
}

androidComponents {
    onVariants { variant ->
        // Computed when BuildConfig is generated, after copyHelper ran; never at configuration time.
        variant.buildConfigFields?.put("HELPER_SHA256", helperJar.map { jar ->
            val digest = MessageDigest.getInstance("SHA-256").digest(jar.readBytes())
            BuildConfigField("String", "\"" + digest.joinToString("") { "%02x".format(it) } + "\"", "SHA-256 of assets/anmirror-helper.jar")
        })
    }
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }.configureEach {
    dependsOn(copyHelper)
}

// LicenseAssetsTest: the bundled licence texts and NOTICE (assets/licenses) against the repository NOTICE
// and the release runtime classpath, so a new dependency can't ship without its NOTICE line.
tasks.withType<Test>().configureEach {
    val notice = rootProject.file("../NOTICE")
    val licenses = file("src/main/assets/licenses")
    inputs.file(notice).withPropertyName("notice").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(licenses).withPropertyName("licenses").withPathSensitivity(PathSensitivity.RELATIVE)
    val modules = configurations.named("ossReleaseRuntimeClasspath")
        .flatMap { it.incoming.resolutionResult.rootComponent }
        .map { root ->
            val seen = mutableSetOf<org.gradle.api.artifacts.component.ComponentIdentifier>()
            val out = sortedSetOf<String>()
            val queue = ArrayDeque(listOf(root))
            while (queue.isNotEmpty()) {
                for (dep in queue.removeFirst().dependencies) {
                    val selected = (dep as? org.gradle.api.artifacts.result.ResolvedDependencyResult)?.selected ?: continue
                    if (!seen.add(selected.id)) continue
                    (selected.id as? org.gradle.api.artifacts.component.ModuleComponentIdentifier)
                        ?.let { out += "${it.group}:${it.module}" }
                    queue += selected
                }
            }
            out.joinToString(",")
        }
    inputs.property("runtimeModules", modules)
    jvmArgumentProviders.add(CommandLineArgumentProvider {
        listOf(
            "-Danmirror.notice=${notice.absolutePath}",
            "-Danmirror.licenses=${licenses.absolutePath}",
            "-Danmirror.runtimeModules=${modules.get()}",
        )
    })
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
    implementation(project(":feature:photos"))
    implementation(project(":feature:browse"))
    implementation(project(":feature:media"))
    implementation(project(":feature:dnd"))
    implementation(project(":feature:proximity"))
    implementation(project(":feature:input"))
    implementation(project(":feature:mirror"))
    implementation(project(":core:adb"))
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
