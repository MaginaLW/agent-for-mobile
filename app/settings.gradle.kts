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
val tabletC1bIsolatedBuild = providers.gradleProperty("tabletC1bIsolatedBuild").orNull
tabletC1bIsolatedBuild?.let { value ->
    check(value == "true" || value == "false") {
        "tabletC1bIsolatedBuild must be exactly true or false"
    }
}
if (tabletC1bIsolatedBuild != "true") {
    include(":gateway")
}
include(":tablet-c1b-probe")
