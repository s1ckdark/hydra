import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.dsl.CommonExtension
import com.android.build.gradle.LibraryExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.getByType

/**
 * Turns on Compose and adds the BOM-pinned Compose dependencies. Applied on
 * top of either hydra.android.application or hydra.android.library, so it
 * configures whichever extension the module actually has.
 */
class HydraAndroidComposePlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("org.jetbrains.kotlin.plugin.compose")

        val configure: CommonExtension<*, *, *, *, *, *>.() -> Unit = {
            buildFeatures { compose = true }
        }
        extensions.findByType(ApplicationExtension::class.java)?.configure()
            ?: extensions.configure<LibraryExtension> { configure() }

        val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")
        val bom = libs.findLibrary("compose-bom").get()
        dependencies {
            add("implementation", platform(bom))
            add("implementation", libs.findLibrary("compose-ui").get())
            add("implementation", libs.findLibrary("compose-material3").get())
            add("implementation", libs.findLibrary("compose-ui-tooling-preview").get())
            add("debugImplementation", platform(bom))
            add("debugImplementation", libs.findLibrary("compose-ui-tooling").get())
        }
    }
}
