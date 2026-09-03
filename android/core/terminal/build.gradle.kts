plugins {
    id("hydra.android.library")
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android {
    // Namespace is com.termux.view, not our package: the vendored
    // textselection classes import `com.termux.view.R`, and the namespace is
    // what decides where R is generated. Matching it keeps the vendored Java
    // byte-for-byte. Our own Kotlin still lives in its own packages.
    namespace = "com.termux.view"
    // The vendored Termux Java predates our lint config and is not ours to fix.
    lint { checkOnly += emptySet<String>(); abortOnError = false }
}

dependencies {
    api(project(":core:ssh"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
