plugins {
    id("hydra.android.library")
    id("hydra.android.compose")
}

android { namespace = "com.hydra.android.core.designsystem" }

dependencies {
    implementation(project(":core:model"))
    implementation(libs.compose.material.icons.extended)
}
