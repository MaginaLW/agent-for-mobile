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
rootProject.name = "mobile-agent-gateway"
include(":gateway")
if (providers.gradleProperty("localTestbench").orNull == "true") {
    include(":test-target")
}
