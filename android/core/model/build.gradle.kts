plugins {
    id("hydra.android.library")
    alias(libs.plugins.kotlin.serialization)
}

android { namespace = "com.hydra.android.core.model" }

dependencies {
    api(libs.kotlinx.serialization.json)
    api(libs.kotlinx.datetime)
    testImplementation(libs.junit)
}
