plugins { `kotlin-dsl` }

dependencies {
    compileOnly("com.android.tools.build:gradle:8.9.1")
    compileOnly("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.10")
}

gradlePlugin {
    plugins {
        register("hydraAndroidApplication") {
            id = "hydra.android.application"
            implementationClass = "HydraAndroidApplicationPlugin"
        }
        register("hydraAndroidLibrary") {
            id = "hydra.android.library"
            implementationClass = "HydraAndroidLibraryPlugin"
        }
        register("hydraAndroidCompose") {
            id = "hydra.android.compose"
            implementationClass = "HydraAndroidComposePlugin"
        }
    }
}
