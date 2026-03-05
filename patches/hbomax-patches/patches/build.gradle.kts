plugins {
    alias(libs.plugins.kotlin.jvm)
}

group = "app.revanced"
version = "1.0.0"

dependencies {
    implementation(libs.revanced.patcher)
    implementation(libs.smali)
}

kotlin {
    jvmToolchain(17)
}
