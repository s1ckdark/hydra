import com.android.build.gradle.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

/** Shared Android library configuration: SDK levels, Java target, JUnit. */
class HydraAndroidLibraryPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.library")
        pluginManager.apply("org.jetbrains.kotlin.android")

        extensions.configure<LibraryExtension> {
            compileSdk = 36
            defaultConfig {
                minSdk = 26
                testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
            }
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
            // BouncyCastle (via sshj) ships duplicate META-INF entries that break
            // both the app APK and any androidTest APK that links a module
            // depending on it.
            packaging {
                resources {
                    excludes += setOf(
                        "META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA",
                        "META-INF/versions/**", "META-INF/INDEX.LIST",
                        "META-INF/LICENSE*", "META-INF/NOTICE*",
                    )
                }
            }
        }
        // Build runs on JDK 21, but both Java and Kotlin emit 17 bytecode.
        // Letting the Kotlin toolchain default to 21 while AGP compiles Java at
        // 17 fails KSP with an "Inconsistent JVM-target compatibility" error.
        extensions.configure<KotlinAndroidProjectExtension> {
            compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
        }
        dependencies { add("testImplementation", "junit:junit:4.13.2") }
    }
}
