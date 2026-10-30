pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // libadb-android is published on JitPack only; nothing else may resolve from there.
        maven("https://jitpack.io") { content { includeGroupByRegex("com\\.github\\.MuntashirAkon.*") } }
    }
}

rootProject.name = "android-mirroring"

include(":app")
include(":core:protocol")
include(":core:connection")
include(":core:transfer")
include(":core:adb")
include(":feature:status")
include(":feature:find")
include(":feature:notify")
include(":feature:contacts")
include(":feature:calls")
include(":feature:clipboard")
include(":feature:share")
include(":feature:screenshots")
include(":feature:photos")
include(":feature:browse")
include(":feature:media")
include(":feature:dnd")
include(":feature:proximity")
include(":feature:input")
include(":tools:phone-sim")
include(":helper")
