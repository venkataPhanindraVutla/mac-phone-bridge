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
    }
}

rootProject.name = "android-mirroring"

include(":app")
include(":core:protocol")
include(":core:connection")
include(":core:transfer")
include(":feature:status")
include(":feature:find")
include(":feature:notify")
include(":feature:contacts")
include(":feature:calls")
include(":feature:clipboard")
include(":feature:share")
include(":tools:phone-sim")
