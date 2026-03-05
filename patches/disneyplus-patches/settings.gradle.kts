pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        maven { url = uri("https://maven.pkg.github.com/ReVanced/revanced-patcher") }
    }
}

plugins {
    id("app.revanced.patches") version "1.0.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
        google()
        maven {
            url = uri("https://maven.pkg.github.com/ReVanced/revanced-patcher")
            credentials {
                username = providers.gradleProperty("gpr.user").orElse(System.getenv("GITHUB_ACTOR") ?: "").get()
                password = providers.gradleProperty("gpr.key").orElse(System.getenv("GITHUB_TOKEN") ?: "").get()
            }
        }
    }
}

rootProject.name = "disneyplus-patches"

include(":patches")
