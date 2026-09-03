pluginManagement {
    includeBuild("build-logic")
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "hydra-android"
include(":app")
include(":core:model", ":core:network", ":core:data", ":core:designsystem", ":core:ssh", ":core:terminal")
include(":feature:dashboard", ":feature:chat", ":feature:settings", ":feature:devices", ":feature:terminal")
