plugins {
    id("hydra.android.library")
    id("hydra.android.compose")
}

android { namespace = "com.hydra.android.core.designsystem" }

dependencies {
    implementation(libs.compose.material.icons.extended)
}
