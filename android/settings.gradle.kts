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
include(":feature:status")
include(":feature:find")
include(":tools:phone-sim")
