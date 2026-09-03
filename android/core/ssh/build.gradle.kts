plugins {
    id("hydra.android.library")
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android { namespace = "com.hydra.android.core.ssh" }

dependencies {
    api(project(":core:model"))
    implementation(project(":core:data"))
    implementation(libs.sshj)
    implementation(libs.bouncycastle.prov)
    implementation(libs.slf4j.android)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
