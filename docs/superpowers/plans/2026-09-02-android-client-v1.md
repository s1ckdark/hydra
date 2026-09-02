# Hydra Android Client v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native Kotlin + Jetpack Compose Android client for Hydra with three working tabs — 설정, 대시보드, Chat — talking to the existing Go backend on `:8080`.

**Architecture:** A Gradle multi-module Android project under `android/`, wired with Hilt. `:core:model` holds serializable data classes, `:core:network` owns Retrofit/OkHttp and two interceptors (runtime base-URL rewriting, bearer auth), `:core:data` exposes repositories returning `Result<T>`, and three `:feature:*` modules each export a `NavGraphBuilder` extension that `:app` assembles into a bottom-nav `NavHost`.

**Tech Stack:** Kotlin 2.x, Jetpack Compose (Material3), Hilt, Retrofit + OkHttp, kotlinx.serialization, kotlinx-datetime, DataStore Preferences, Android Keystore, JUnit4 + MockWebServer + Turbine.

**Spec:** `docs/superpowers/specs/2026-09-02-android-client-design.md`

## Global Constraints

- All Android code lives under `android/`. Do not touch Go (`cmd/`, `internal/`) or Swift (`Hydra/`) sources.
- Package root: `com.hydra.android`. Application id: `com.hydra.android`.
- compileSdk 36, targetSdk 36, minSdk 26. Installed SDK has `platforms/android-35`, `platforms/android-36`, `build-tools/36.1.0` — do not require anything else.
- `JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS` (JDK 21). `java` is NOT on PATH; every Gradle invocation in this plan exports `JAVA_HOME` explicitly.
- `ANDROID_HOME=/Users/dave/Library/Android/sdk` is already set in the shell environment.
- Server JSON is camelCase and matches Go struct tags exactly (`internal/domain/device.go:16-38`) — do not add `@SerialName` unless a name genuinely differs.
- Timestamps are RFC3339 and may or may not carry fractional seconds. Every `Instant` field must decode both forms.
- Auth header format is exactly `Authorization: Bearer <key>` (`Hydra/Hydra/Services/APIClient.swift:329`).
- Error bodies are `{"error": "..."}` (`Hydra/Hydra/Services/APIClient.swift:336`).
- Korean UI strings are used where the iOS app uses Korean (tab labels, settings labels). Do not localize; hardcode to match.
- Every task ends with a commit. Work on branch `feat/android-client`.

### Deliberate divergences from iOS — do not "fix" these back

1. **Auth on GET.** iOS's private `get<T>` never calls `applyAuth` (`APIClient.swift:300-304`), so iOS sends no bearer token on GET requests — only POST/DELETE carry it. Android's `AuthInterceptor` applies to *all* requests. This is intentional and more correct; the server tolerates the header on GET today.
2. **Polling lifecycle.** iOS uses manual `startPolling`/`stopPolling` (`DashboardViewModel.swift:161-173`). Android uses `stateIn(..., SharingStarted.WhileSubscribed(5_000), ...)` so subscription drives the loop.
3. **Secret storage.** iOS uses Keychain via `CredentialStore`. Android uses a hand-rolled Android Keystore AES/GCM wrapper, not `androidx.security-crypto` (deprecated in Jetpack).

---

## File Structure

```
android/
├── settings.gradle.kts                  module registry + repositories
├── build.gradle.kts                     root, plugins declared apply-false
├── gradle.properties                    AndroidX, JVM args
├── gradle/libs.versions.toml            single source of dependency versions
├── gradlew, gradle/wrapper/             Gradle wrapper (bootstrapped in Task 1)
├── build-logic/                         convention plugins (application/library/compose)
├── app/                                 Application, MainActivity, NavHost, bottom bar
├── core/
│   ├── model/                           @Serializable data classes + Instant serializer
│   ├── network/                         Retrofit service, interceptors, error mapping, Hilt module
│   ├── data/                            repositories, DataStore settings, Keystore secret store
│   └── designsystem/                    Theme, Color, Typography, HydraCard
└── feature/
    ├── dashboard/                       DashboardViewModel + Compose sections
    ├── chat/                            ChatViewModel + Compose chat UI
    └── settings/                        SettingsViewModel + Compose form
```

Responsibilities are one-per-file: each model type gets its own file mirroring the iOS `Models/` layout; each interceptor gets its own file; each dashboard section is its own composable file so no single file repeats the 877-line `DashboardScreen.swift` problem.

---

### Task 1: Gradle bootstrap and buildable `:app` skeleton

This task's deliverable is *a build that works*. Everything version-related is settled here so no later task discovers a broken version matrix.

**Files:**
- Create: `android/settings.gradle.kts`, `android/build.gradle.kts`, `android/gradle.properties`, `android/gradle/libs.versions.toml`
- Create: `android/build-logic/settings.gradle.kts`, `android/build-logic/build.gradle.kts`
- Create: `android/build-logic/src/main/kotlin/HydraAndroidApplicationPlugin.kt`, `HydraAndroidLibraryPlugin.kt`, `HydraAndroidComposePlugin.kt`
- Create: `android/app/build.gradle.kts`, `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/kotlin/com/hydra/android/HydraApplication.kt`, `MainActivity.kt`
- Create: `android/app/src/main/res/xml/network_security_config.xml`, `android/app/src/main/res/values/strings.xml`
- Test: `android/app/src/test/kotlin/com/hydra/android/BuildSmokeTest.kt`
- Modify: `.gitignore` (repo root), `Makefile` (repo root)

**Interfaces:**
- Consumes: nothing.
- Produces: convention plugin ids `hydra.android.application`, `hydra.android.library`, `hydra.android.compose`; version catalog accessors `libs.*`; `HydraApplication` annotated `@HiltAndroidApp`.

- [ ] **Step 1: Bootstrap the Gradle wrapper**

`gradle` is not on PATH. Download a Gradle distribution once and use it to generate the wrapper, then discard it.

```bash
cd /Users/dave/iWorks/hydra
mkdir -p android
export JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS
cd /tmp && curl -fsSL -o gradle-8.13-bin.zip \
  https://services.gradle.org/distributions/gradle-8.13-bin.zip
unzip -q -o gradle-8.13-bin.zip
cd /Users/dave/iWorks/hydra/android
/tmp/gradle-8.13/bin/gradle wrapper --gradle-version 8.13 --distribution-type bin
```

Expected: `android/gradlew`, `android/gradlew.bat`, `android/gradle/wrapper/gradle-wrapper.jar`, `android/gradle/wrapper/gradle-wrapper.properties` exist.

Verify: `cd /Users/dave/iWorks/hydra/android && JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS ./gradlew --version` prints `Gradle 8.13`.

- [ ] **Step 2: Write the version catalog**

Create `android/gradle/libs.versions.toml`:

```toml
[versions]
agp = "8.9.1"
kotlin = "2.1.10"
ksp = "2.1.10-1.0.31"
hilt = "2.55"
composeBom = "2025.02.00"
coreKtx = "1.15.0"
lifecycle = "2.8.7"
activityCompose = "1.10.0"
navigationCompose = "2.8.7"
retrofit = "2.11.0"
okhttp = "4.12.0"
retrofitSerialization = "1.0.0"
serialization = "1.8.0"
datetime = "0.6.1"
datastore = "1.1.2"
hiltNavigationCompose = "1.2.0"
junit = "4.13.2"
turbine = "1.2.0"
coroutinesTest = "1.10.1"

[libraries]
androidx-core-ktx = { module = "androidx.core:core-ktx", version.ref = "coreKtx" }
androidx-activity-compose = { module = "androidx.activity:activity-compose", version.ref = "activityCompose" }
androidx-lifecycle-runtime-ktx = { module = "androidx.lifecycle:lifecycle-runtime-ktx", version.ref = "lifecycle" }
androidx-lifecycle-runtime-compose = { module = "androidx.lifecycle:lifecycle-runtime-compose", version.ref = "lifecycle" }
androidx-lifecycle-viewmodel-compose = { module = "androidx.lifecycle:lifecycle-viewmodel-compose", version.ref = "lifecycle" }
androidx-navigation-compose = { module = "androidx.navigation:navigation-compose", version.ref = "navigationCompose" }
androidx-datastore-preferences = { module = "androidx.datastore:datastore-preferences", version.ref = "datastore" }
compose-bom = { module = "androidx.compose:compose-bom", version.ref = "composeBom" }
compose-ui = { module = "androidx.compose.ui:ui" }
compose-ui-tooling-preview = { module = "androidx.compose.ui:ui-tooling-preview" }
compose-ui-tooling = { module = "androidx.compose.ui:ui-tooling" }
compose-material3 = { module = "androidx.compose.material3:material3" }
compose-material-icons-extended = { module = "androidx.compose.material:material-icons-extended" }
hilt-android = { module = "com.google.dagger:hilt-android", version.ref = "hilt" }
hilt-compiler = { module = "com.google.dagger:hilt-android-compiler", version.ref = "hilt" }
hilt-navigation-compose = { module = "androidx.hilt:hilt-navigation-compose", version.ref = "hiltNavigationCompose" }
retrofit = { module = "com.squareup.retrofit2:retrofit", version.ref = "retrofit" }
retrofit-serialization = { module = "com.jakewharton.retrofit:retrofit2-kotlinx-serialization-converter", version.ref = "retrofitSerialization" }
okhttp = { module = "com.squareup.okhttp3:okhttp", version.ref = "okhttp" }
okhttp-logging = { module = "com.squareup.okhttp3:logging-interceptor", version.ref = "okhttp" }
okhttp-mockwebserver = { module = "com.squareup.okhttp3:mockwebserver", version.ref = "okhttp" }
kotlinx-serialization-json = { module = "org.jetbrains.kotlinx:kotlinx-serialization-json", version.ref = "serialization" }
kotlinx-datetime = { module = "org.jetbrains.kotlinx:kotlinx-datetime", version.ref = "datetime" }
kotlinx-coroutines-test = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-test", version.ref = "coroutinesTest" }
junit = { module = "junit:junit", version.ref = "junit" }
turbine = { module = "app.cash.turbine:turbine", version.ref = "turbine" }

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
kotlin-compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
```

If any coordinate fails to resolve in Step 8, bump only that version and re-run. Do not swap libraries.

- [ ] **Step 3: Write settings, root build, and gradle.properties**

`android/settings.gradle.kts`:

```kotlin
pluginManagement {
    includeBuild("build-logic")
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "hydra-android"
include(":app")
include(":core:model", ":core:network", ":core:data", ":core:designsystem")
include(":feature:dashboard", ":feature:chat", ":feature:settings")
```

`android/build.gradle.kts`:

```kotlin
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.ksp) apply false
    alias(libs.plugins.hilt) apply false
}
```

`android/gradle.properties`:

```properties
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g
org.gradle.caching=true
org.gradle.configuration-cache=true
android.useAndroidX=true
android.nonTransitiveRClass=true
kotlin.code.style=official
```

- [ ] **Step 4: Write the build-logic convention plugins**

`android/build-logic/settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
    versionCatalogs { create("libs") { from(files("../gradle/libs.versions.toml")) } }
}
rootProject.name = "build-logic"
```

`android/build-logic/build.gradle.kts`:

```kotlin
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
```

`android/build-logic/src/main/kotlin/HydraAndroidLibraryPlugin.kt`:

```kotlin
import com.android.build.gradle.LibraryExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.plugins.JavaPluginExtension
import org.gradle.jvm.toolchain.JavaLanguageVersion
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies

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
                sourceCompatibility = org.gradle.api.JavaVersion.VERSION_17
                targetCompatibility = org.gradle.api.JavaVersion.VERSION_17
            }
        }
        extensions.configure<JavaPluginExtension> {
            toolchain { languageVersion.set(JavaLanguageVersion.of(21)) }
        }
        dependencies { add("testImplementation", "junit:junit:4.13.2") }
    }
}
```

`HydraAndroidApplicationPlugin.kt` is the same shape but applies `com.android.application`, configures `ApplicationExtension`, and sets `defaultConfig { applicationId = "com.hydra.android"; targetSdk = 36; versionCode = 1; versionName = "0.1.0" }`.

`HydraAndroidComposePlugin.kt` applies `org.jetbrains.kotlin.plugin.compose`, sets `buildFeatures.compose = true` on whichever of `ApplicationExtension`/`LibraryExtension` is present, and adds the Compose BOM plus `compose-ui`, `compose-material3`, `compose-ui-tooling-preview` to `implementation` and `compose-ui-tooling` to `debugImplementation`.

- [ ] **Step 5: Write the `:app` module**

`android/app/build.gradle.kts`:

```kotlin
plugins {
    id("hydra.android.application")
    id("hydra.android.compose")
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android { namespace = "com.hydra.android" }
dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
}
```

`android/app/src/main/kotlin/com/hydra/android/HydraApplication.kt`:

```kotlin
package com.hydra.android

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class HydraApplication : Application()
```

`android/app/src/main/kotlin/com/hydra/android/MainActivity.kt`:

```kotlin
package com.hydra.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface { Text("Hydra") }
            }
        }
    }
}
```

`android/app/src/main/res/xml/network_security_config.xml` — see the spec's "Cleartext HTTP" section for why this is broad:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  The server address is arbitrary user input (typically a Tailscale IP over
  plain HTTP), so the reachable hosts cannot be enumerated ahead of time and
  network_security_config has no CIDR form. Cleartext is therefore permitted
  globally. Revisit once the server offers HTTPS.
-->
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

`android/app/src/main/res/values/strings.xml`:

```xml
<resources>
    <string name="app_name">Hydra</string>
</resources>
```

`android/app/src/main/AndroidManifest.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <application
        android:name=".HydraApplication"
        android:label="@string/app_name"
        android:networkSecurityConfig="@xml/network_security_config"
        android:supportsRtl="true"
        android:theme="@style/Theme.Material3.DayNight.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

- [ ] **Step 6: Write the failing smoke test**

`android/app/src/test/kotlin/com/hydra/android/BuildSmokeTest.kt`:

```kotlin
package com.hydra.android

import org.junit.Assert.assertEquals
import org.junit.Test

class BuildSmokeTest {
    @Test
    fun `module builds and runs unit tests`() {
        assertEquals("com.hydra.android", HydraApplication::class.java.`package`.name)
    }
}
```

- [ ] **Step 7: Create the placeholder module directories**

Every module named in `settings.gradle.kts` must exist or configuration fails. Create a minimal `build.gradle.kts` and namespace for each of the six library modules now; later tasks fill them in.

```bash
cd /Users/dave/iWorks/hydra/android
for m in core/model core/network core/data core/designsystem feature/dashboard feature/chat feature/settings; do
  ns="com.hydra.android.$(echo $m | tr '/' '.')"
  mkdir -p "$m/src/main/kotlin"
  cat > "$m/build.gradle.kts" <<EOF
plugins { id("hydra.android.library") }
android { namespace = "$ns" }
EOF
done
```

- [ ] **Step 8: Run the build and the test**

```bash
cd /Users/dave/iWorks/hydra/android
export JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

Expected: `BUILD SUCCESSFUL`, and `app/build/outputs/apk/debug/app-debug.apk` exists.

If a dependency fails to resolve, bump only that one version in `libs.versions.toml` and re-run. This step is the version-matrix gate for the whole plan — do not proceed until it is green.

- [ ] **Step 9: Wire repo-root ignore and Make targets**

Append to `.gitignore`:

```
# Android client
android/.gradle/
android/build/
android/**/build/
android/local.properties
android/build-logic/.gradle/
android/.kotlin/
```

Add to `Makefile` (and append `android-build android-test` to the `.PHONY` line):

```makefile
## Android targets

ANDROID_JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS

android-build: ## Build the Android debug APK
	@echo "Building Android client..."
	cd android && JAVA_HOME=$(ANDROID_JAVA_HOME) ./gradlew :app:assembleDebug

android-test: ## Run Android unit tests
	@echo "Testing Android client..."
	cd android && JAVA_HOME=$(ANDROID_JAVA_HOME) ./gradlew testDebugUnitTest
```

Do NOT add these to `build:` or `test:` — the Go CI must not acquire a JDK/Android SDK dependency.

- [ ] **Step 10: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android .gitignore Makefile
git commit -m "feat(android): Gradle 멀티 모듈 스캐폴드 + :app 스켈레톤"
```

---

### Task 2: `:core:model` — serializable models

**Files:**
- Modify: `android/core/model/build.gradle.kts`
- Create: `android/core/model/src/main/kotlin/com/hydra/android/core/model/InstantSerializer.kt`
- Create: `.../core/model/Device.kt`, `Orch.kt`, `NagaTask.kt`, `GpuMonitor.kt`, `DeviceMetrics.kt`, `Chat.kt`, `AgentPlan.kt`
- Test: `android/core/model/src/test/kotlin/com/hydra/android/core/model/SerializationTest.kt`

**Interfaces:**
- Consumes: nothing.
- Produces: `Device`, `Orch`, `NagaTask`, `GpuMonitorResponse`, `GpuNodeStatus`, `GpuInfo`, `GpuProcess`, `DeviceMetrics`, `MetricsSnapshotResponse`, `HealthResponse`, `ChatTurn`, `ChatRequest`, `ChatResponse`, `AgentPlan`, `AgentAction`, `ActionResult`, `AgentExecuteRequest`, `AgentExecuteResponse`, and `object InstantSerializer : KSerializer<Instant>`.

- [ ] **Step 1: Add module dependencies**

`android/core/model/build.gradle.kts`:

```kotlin
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
```

- [ ] **Step 2: Write the failing serialization tests**

`SerializationTest.kt`:

```kotlin
package com.hydra.android.core.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `decodes RFC3339 with fractional seconds`() {
        val task = json.decodeFromString<NagaTask>(
            """{"id":"t1","type":"exec","status":"running","priority":"normal",
               "assignedDeviceId":null,"error":null,
               "createdAt":"2026-09-02T10:00:00.123456789Z",
               "completedAt":null,"retryCount":0}"""
        )
        assertEquals("t1", task.id)
        assertTrue(task.isRunning)
    }

    @Test
    fun `decodes RFC3339 without fractional seconds`() {
        // Go's time.Time omits the fraction when it is zero, so both forms
        // arrive from the same server. iOS handles this at APIClient.swift:20-26.
        val task = json.decodeFromString<NagaTask>(
            """{"id":"t2","type":"exec","status":"completed","priority":"normal",
               "assignedDeviceId":null,"error":null,
               "createdAt":"2026-09-02T10:00:00Z",
               "completedAt":"2026-09-02T10:01:00Z","retryCount":0}"""
        )
        assertEquals("t2", task.id)
        assertTrue(task.isCompleted)
    }

    @Test
    fun `ChatTurn does not serialize its client-side id`() {
        val encoded = json.encodeToString(ChatTurn(role = "user", content = "hi"))
        assertFalse(encoded.contains("\"id\""))
    }

    @Test
    fun `AgentAction and ActionResult do not serialize their client-side ids`() {
        // AgentPlan is echoed back to POST /api/agent/execute, so a leaked id
        // would ride along into the execute request.
        val action = AgentAction(type = "exec", args = buildJsonObject { put("cmd", "ls") })
        assertFalse(json.encodeToString(action).contains("\"id\""))
        val result = ActionResult(type = "exec", status = "ok", output = null, error = null)
        assertFalse(json.encodeToString(result).contains("\"id\""))
    }

    @Test
    fun `AgentAction args survives a decode-encode round trip`() {
        val decoded = json.decodeFromString<AgentAction>(
            """{"type":"exec","args":{"deviceId":"d1","command":"uptime","timeout":30}}"""
        )
        val reencoded = json.encodeToString(decoded)
        assertTrue(reencoded.contains("\"deviceId\":\"d1\""))
        assertTrue(reencoded.contains("\"timeout\":30"))
    }

    @Test
    fun `Device computes online state and short name`() {
        val d = json.decodeFromString<Device>(
            """{"id":"d1","name":"","hostname":"high15","ipAddresses":["10.0.0.2"],
               "tailscaleIp":"100.1.2.3","os":"linux","status":"online","isExternal":false,
               "tags":null,"user":"dave","lastSeen":"2026-09-02T10:00:00Z",
               "sshEnabled":true,"hasGpu":true,"gpuModel":"RTX 4090","gpuCount":2}"""
        )
        assertTrue(d.isOnline)
        assertEquals("high15", d.displayName)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:model:testDebugUnitTest
```

Expected: FAIL — unresolved references to `NagaTask`, `ChatTurn`, `AgentAction`, `ActionResult`, `Device`.

- [ ] **Step 4: Write `InstantSerializer`**

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * RFC3339 with or without fractional seconds. Go's time.Time omits the
 * fraction when it is zero, so a single endpoint returns both shapes.
 * kotlinx-datetime's Instant.parse already accepts both; this serializer
 * exists to give a clear error message and a single point of change.
 */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor =
        PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): Instant {
        val raw = decoder.decodeString()
        return runCatching { Instant.parse(raw) }.getOrElse {
            throw IllegalArgumentException("Invalid RFC3339 instant: $raw", it)
        }
    }

    override fun serialize(encoder: Encoder, value: Instant) =
        encoder.encodeString(value.toString())
}
```

- [ ] **Step 5: Write the model files**

`Device.kt` — mirrors `Hydra/Hydra/Models/Device.swift`:

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class Device(
    val id: String,
    val name: String,
    val hostname: String,
    val ipAddresses: List<String> = emptyList(),
    val tailscaleIp: String = "",
    val os: String = "",
    val status: String,
    val isExternal: Boolean = false,
    val tags: List<String>? = null,
    val user: String = "",
    @Serializable(with = InstantSerializer::class) val lastSeen: Instant,
    val sshEnabled: Boolean = false,
    val hasGpu: Boolean = false,
    val gpuModel: String? = null,
    val gpuCount: Int = 0,
) {
    val isOnline: Boolean get() = status == "online"
    val displayName: String get() = name.ifEmpty { hostname }
    /** Hostname up to the first dot — the short label used on cards. */
    val shortName: String get() = hostname.substringBefore('.').ifEmpty { displayName }
}
```

`NagaTask.kt`:

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class NagaTask(
    val id: String,
    val type: String,
    val status: String,
    val priority: String = "",
    val assignedDeviceId: String? = null,
    val error: String? = null,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
    @Serializable(with = InstantSerializer::class) val completedAt: Instant? = null,
    val retryCount: Int = 0,
) {
    val isRunning: Boolean get() = status == "running"
    val isCompleted: Boolean get() = status == "completed"
    val isFailed: Boolean get() = status == "failed"
    val isPending: Boolean
        get() = status == "pending" || status == "queued" || status == "assigned"
    /** Sort key matching iOS `recentTasks`: completedAt ?? createdAt. */
    val sortInstant: Instant get() = completedAt ?: createdAt
}
```

`Orch.kt`:

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class Orch(
    val id: String,
    val name: String,
    val description: String = "",
    val mode: String = "",
    val status: String,
    val coordinatorId: String = "",
    val workerIds: List<String> = emptyList(),
    val dashboardUrl: String = "",
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
    @Serializable(with = InstantSerializer::class) val updatedAt: Instant,
) {
    val workerCount: Int get() = workerIds.size
    val isRunning: Boolean get() = status == "running"
}
```

`GpuMonitor.kt` — mirrors `Models/GPUMonitor.swift`; every extended nvidia-smi field is nullable so older servers decode:

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class GpuMonitorResponse(
    @Serializable(with = InstantSerializer::class) val timestamp: Instant,
    val nodes: List<GpuNodeStatus> = emptyList(),
    val nodeCount: Int = 0,
)

@Serializable
data class GpuNodeStatus(
    val deviceId: String,
    val deviceName: String = "",
    val ip: String = "",
    val gpuModel: String = "",
    val gpuCount: Int = 0,
    val gpus: List<GpuInfo>? = null,
    val error: String? = null,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()
}

@Serializable
data class GpuInfo(
    val index: Int,
    val name: String = "",
    val utilizationPercent: Double = 0.0,
    val memoryUsedMB: Int = 0,
    val memoryTotalMB: Int = 0,
    val temperatureC: Int = 0,
    val powerDrawW: Double = 0.0,
    val powerLimitW: Double = 0.0,
    val processes: List<GpuProcess>? = null,
    val clockSMMHz: Int? = null,
    val clockMemoryMHz: Int? = null,
    val fanSpeedPercent: Int? = null,
    val pstate: String? = null,
    val pcieLinkGen: Int? = null,
    val pcieLinkWidth: Int? = null,
) {
    val memoryPercent: Double
        get() = if (memoryTotalMB > 0) memoryUsedMB.toDouble() / memoryTotalMB * 100 else 0.0
}

@Serializable
data class GpuProcess(val pid: Int, val name: String = "", val usedMemoryMB: Int = 0)
```

`DeviceMetrics.kt`:

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

@Serializable
data class DeviceMetrics(
    val deviceId: String,
    val cpu: CpuMetrics,
    val memory: MemoryMetrics,
    val disk: DiskMetrics,
    val uptimeSeconds: Long? = null,
    @Serializable(with = InstantSerializer::class) val collectedAt: Instant,
    val error: String? = null,
    val suppressed: Boolean? = null,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()
    val isSuppressed: Boolean get() = suppressed == true
}

@Serializable
data class CpuMetrics(
    val usagePercent: Double = 0.0,
    val cores: Int = 0,
    val modelName: String = "",
    val loadAvg1: Double = 0.0,
    val loadAvg5: Double = 0.0,
    val loadAvg15: Double = 0.0,
)

@Serializable
data class MemoryMetrics(
    val total: Long = 0,
    val used: Long = 0,
    val free: Long = 0,
    val available: Long = 0,
    val usagePercent: Double = 0.0,
    val swapTotal: Long = 0,
    val swapUsed: Long = 0,
    val swapFree: Long = 0,
)

@Serializable
data class DiskMetrics(val partitions: List<Partition>? = null)

@Serializable
data class Partition(
    val mountPoint: String,
    val device: String = "",
    val total: Long = 0,
    val used: Long = 0,
    val free: Long = 0,
    val usagePercent: Double = 0.0,
)

@Serializable
data class MetricsSnapshotResponse(
    val devices: Map<String, DeviceMetrics> = emptyMap(),
    @Serializable(with = InstantSerializer::class) val collectedAt: Instant,
)

@Serializable
data class HealthResponse(val status: String, val version: String = "")
```

Note: Swift uses `UInt64` for byte counts; Kotlin has no unsigned Long in the serialization path here, and real values are far below `Long.MAX_VALUE`, so `Long` is correct.

`AgentPlan.kt` — the `@Transient` ids are the point of this file:

```kotlin
package com.hydra.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.util.UUID

/**
 * One action in an LLM-proposed plan. `args` is free-form JSON mirroring the
 * Go side, shown verbatim rather than enumerating every shape.
 *
 * `id` exists only as a stable LazyColumn key and must never be serialized:
 * AgentPlan is echoed back to POST /api/agent/execute, and iOS excludes it
 * too (AgentPlan.swift:10).
 */
@Serializable
data class AgentAction(
    val type: String,
    val args: JsonObject,
) {
    @Transient val id: String = UUID.randomUUID().toString()
    /** "cmd=ls deviceId=d1" — sorted key=value summary for the plan card. */
    val argsSummary: String
        get() = args.entries.sortedBy { it.key }
            .joinToString(" ") { (k, v) -> "$k=${v.unquoted()}" }
}

private fun JsonElement.unquoted(): String = toString().trim('"')

@Serializable
data class AgentPlan(val intent: String, val actions: List<AgentAction> = emptyList())

@Serializable
data class ActionResult(
    val type: String,
    val status: String,
    val output: JsonElement? = null,
    val error: String? = null,
) {
    @Transient val id: String = UUID.randomUUID().toString()
    val isOk: Boolean get() = status == "ok"
}

@Serializable
data class AgentExecuteRequest(val plan: AgentPlan)

@Serializable
data class AgentExecuteResponse(
    val results: List<ActionResult> = emptyList(),
    val summary: String? = null,
)
```

`Chat.kt`:

```kotlin
package com.hydra.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import java.util.UUID

/**
 * One row in the chat history. `role` mirrors the Go side exactly:
 * user | assistant_ask | assistant_plan | system_result.
 */
@Serializable
data class ChatTurn(
    val role: String,
    val content: String,
    val plan: AgentPlan? = null,
    val results: List<ActionResult>? = null,
) {
    @Transient val id: String = UUID.randomUUID().toString()
}

@Serializable
data class ChatRequest(
    val history: List<ChatTurn>,
    val message: String,
    val instruction: String? = null,
)

@Serializable
data class ChatResponse(
    val type: String,
    val message: String,
    val plan: AgentPlan? = null,
)
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:model:testDebugUnitTest
```

Expected: PASS, 6 tests.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/model
git commit -m "feat(android): 서버 계약 모델 + RFC3339 직렬화"
```

---

### Task 3: `:core:network` — interceptors and error mapping

**Files:**
- Modify: `android/core/network/build.gradle.kts`
- Create: `.../core/network/ServerConfigProvider.kt`, `BaseUrlInterceptor.kt`, `AuthInterceptor.kt`, `ApiException.kt`, `ErrorMapping.kt`
- Test: `android/core/network/src/test/kotlin/com/hydra/android/core/network/InterceptorTest.kt`, `ErrorMappingTest.kt`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `interface ServerConfigProvider { fun baseUrl(): String; fun apiKey(): String? }`
  - `class BaseUrlInterceptor(private val config: ServerConfigProvider) : Interceptor`
  - `class AuthInterceptor(private val config: ServerConfigProvider) : Interceptor`
  - `class ApiException(val status: Int?, override val message: String) : Exception(message)`
  - `suspend fun <T> apiCall(block: suspend () -> T): Result<T>`

- [ ] **Step 1: Add module dependencies**

```kotlin
plugins {
    id("hydra.android.library")
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android { namespace = "com.hydra.android.core.network" }
dependencies {
    api(project(":core:model"))
    api(libs.retrofit)
    implementation(libs.retrofit.serialization)
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.kotlinx.coroutines.test)
}
```

Also add to `android/build.gradle.kts` nothing new; the Hilt plugin is already declared apply-false in Task 1.

- [ ] **Step 2: Write the failing interceptor tests**

`InterceptorTest.kt`:

```kotlin
package com.hydra.android.core.network

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

private class FakeConfig(var url: String, var key: String?) : ServerConfigProvider {
    override fun baseUrl() = url
    override fun apiKey() = key
}

class InterceptorTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer(); server.start() }
    @After fun tearDown() { server.shutdown() }

    @Test
    fun `base url interceptor rewrites host and port from current config`() {
        val config = FakeConfig(server.url("/").toString().trimEnd('/'), null)
        val client = OkHttpClient.Builder()
            .addInterceptor(BaseUrlInterceptor(config)).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(
            Request.Builder().url("http://placeholder.invalid/api/devices").build()
        ).execute().close()

        val recorded = server.takeRequest()
        assertEquals("/api/devices", recorded.path)
    }

    @Test
    fun `base url interceptor picks up a settings change without rebuilding the client`() {
        // The whole reason this interceptor exists: Retrofit pins its base URL
        // at construction, but the server address is editable at runtime.
        val second = MockWebServer().also { it.start() }
        try {
            val config = FakeConfig(server.url("/").toString().trimEnd('/'), null)
            val client = OkHttpClient.Builder()
                .addInterceptor(BaseUrlInterceptor(config)).build()
            server.enqueue(MockResponse().setBody("{}"))
            second.enqueue(MockResponse().setBody("{}"))

            client.newCall(Request.Builder()
                .url("http://placeholder.invalid/health").build()).execute().close()
            config.url = second.url("/").toString().trimEnd('/')
            client.newCall(Request.Builder()
                .url("http://placeholder.invalid/health").build()).execute().close()

            assertEquals(1, server.requestCount)
            assertEquals(1, second.requestCount)
        } finally { second.shutdown() }
    }

    @Test
    fun `base url interceptor preserves a path prefix and query`() {
        val config = FakeConfig(server.url("/").toString().trimEnd('/'), null)
        val client = OkHttpClient.Builder()
            .addInterceptor(BaseUrlInterceptor(config)).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(Request.Builder()
            .url("http://placeholder.invalid/api/devices?refresh=true").build())
            .execute().close()

        assertEquals("/api/devices?refresh=true", server.takeRequest().path)
    }

    @Test
    fun `auth interceptor omits the header entirely when no key is stored`() {
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(FakeConfig("", null))).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(Request.Builder().url(server.url("/health")).build())
            .execute().close()

        assertNull(server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun `auth interceptor omits the header when the key is blank`() {
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(FakeConfig("", "  "))).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(Request.Builder().url(server.url("/health")).build())
            .execute().close()

        assertNull(server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun `auth interceptor sends a bearer token when a key is stored`() {
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(FakeConfig("", "secret123"))).build()
        server.enqueue(MockResponse().setBody("{}"))

        client.newCall(Request.Builder().url(server.url("/health")).build())
            .execute().close()

        assertEquals("Bearer secret123", server.takeRequest().getHeader("Authorization"))
    }
}
```

`ErrorMappingTest.kt`:

```kotlin
package com.hydra.android.core.network

import kotlinx.coroutines.test.runTest
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response
import java.io.IOException

class ErrorMappingTest {
    private fun http(status: Int, body: String) = HttpException(
        Response.error<Any>(status, body.toResponseBody("application/json".toMediaType()))
    )

    @Test
    fun `io failure maps to a connection message`() = runTest {
        val result = apiCall<Unit> { throw IOException("boom") }
        val e = result.exceptionOrNull() as ApiException
        assertEquals("서버에 연결할 수 없습니다", e.message)
        assertEquals(null, e.status)
    }

    @Test
    fun `401 maps to an invalid key message`() = runTest {
        val result = apiCall<Unit> { throw http(401, """{"error":"nope"}""") }
        val e = result.exceptionOrNull() as ApiException
        assertEquals("API 키가 유효하지 않습니다", e.message)
        assertEquals(401, e.status)
    }

    @Test
    fun `other http errors surface the server error body`() = runTest {
        val result = apiCall<Unit> { throw http(500, """{"error":"device unreachable"}""") }
        val e = result.exceptionOrNull() as ApiException
        assertEquals("device unreachable", e.message)
        assertEquals(500, e.status)
    }

    @Test
    fun `unparseable error body falls back to the status code`() = runTest {
        val result = apiCall<Unit> { throw http(503, "<html>gateway</html>") }
        val e = result.exceptionOrNull() as ApiException
        assertTrue(e.message.contains("503"))
    }

    @Test
    fun `success passes the value through`() = runTest {
        assertEquals("ok", apiCall { "ok" }.getOrNull())
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:network:testDebugUnitTest
```

Expected: FAIL — unresolved references to `ServerConfigProvider`, `BaseUrlInterceptor`, `AuthInterceptor`, `apiCall`, `ApiException`.

- [ ] **Step 4: Write the implementation**

`ServerConfigProvider.kt`:

```kotlin
package com.hydra.android.core.network

/**
 * Live view of the user-editable server settings. Implemented in :core:data
 * over DataStore + the Keystore-backed secret store; the network layer reads
 * it on every request so a settings change takes effect immediately.
 */
interface ServerConfigProvider {
    fun baseUrl(): String
    fun apiKey(): String?
}
```

`BaseUrlInterceptor.kt`:

```kotlin
package com.hydra.android.core.network

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Retrofit fixes its base URL at construction, but the Hydra server address is
 * user-editable at runtime (iOS solves this with APIClient.reloadBaseURL()).
 * Retrofit is built against a placeholder base and this interceptor rewrites
 * scheme/host/port from the current config on every request, so changing the
 * server in Settings needs no object-graph rebuild.
 */
class BaseUrlInterceptor(private val config: ServerConfigProvider) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val configured = config.baseUrl().trim().toHttpUrlOrNull()
            ?: return chain.proceed(request)
        val rewritten = request.url.newBuilder()
            .scheme(configured.scheme)
            .host(configured.host)
            .port(configured.port)
            .build()
        return chain.proceed(request.newBuilder().url(rewritten).build())
    }
}
```

`AuthInterceptor.kt`:

```kotlin
package com.hydra.android.core.network

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Adds `Authorization: Bearer <key>` when a key is stored, and nothing at all
 * when it is absent or blank — an empty header is not the same as no header.
 *
 * Note this applies to GET as well. iOS only authenticates POST/DELETE
 * (APIClient.swift:300-304 never calls applyAuth); sending the header on every
 * request is the intended Android behaviour.
 */
class AuthInterceptor(private val config: ServerConfigProvider) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val key = config.apiKey()?.trim().orEmpty()
        if (key.isEmpty()) return chain.proceed(chain.request())
        return chain.proceed(
            chain.request().newBuilder()
                .header("Authorization", "Bearer $key")
                .build()
        )
    }
}
```

`ApiException.kt` and `ErrorMapping.kt`:

```kotlin
package com.hydra.android.core.network

class ApiException(
    val status: Int?,
    override val message: String,
) : Exception(message)
```

```kotlin
package com.hydra.android.core.network

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import retrofit2.HttpException
import java.io.IOException

private val errorJson = Json { ignoreUnknownKeys = true }

/**
 * Runs a network call and returns Result instead of throwing. The dashboard
 * merges five independent sources, and a thrown exception would let the first
 * failure swallow the rest — failures have to be values here.
 */
suspend fun <T> apiCall(block: suspend () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (e: IOException) {
        Result.failure(ApiException(null, "서버에 연결할 수 없습니다"))
    } catch (e: HttpException) {
        Result.failure(ApiException(e.code(), e.toUserMessage()))
    }

/**
 * Mirrors iOS APIClient.swift:336 — the server reports failures as
 * {"error": "..."}; fall back to the status code when the body is not that.
 */
private fun HttpException.toUserMessage(): String {
    if (code() == 401) return "API 키가 유효하지 않습니다"
    val raw = runCatching { response()?.errorBody()?.string() }.getOrNull()
    val serverMessage = raw?.takeIf { it.isNotBlank() }?.let { body ->
        runCatching {
            errorJson.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
    }
    return serverMessage?.takeIf { it.isNotBlank() } ?: "서버 오류 (${code()})"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:network:testDebugUnitTest
```

Expected: PASS, 11 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/network
git commit -m "feat(android): 런타임 baseURL 재작성 + Bearer 인증 인터셉터"
```

---

### Task 4: `:core:network` — Retrofit service and Hilt module

**Files:**
- Create: `.../core/network/HydraApi.kt`, `NetworkModule.kt`
- Test: `android/core/network/src/test/kotlin/com/hydra/android/core/network/HydraApiTest.kt`

**Interfaces:**
- Consumes: `ServerConfigProvider`, `BaseUrlInterceptor`, `AuthInterceptor` (Task 3); all models (Task 2).
- Produces: `interface HydraApi` with the eight v1 endpoints, and `@Module NetworkModule` providing `OkHttpClient`, `Retrofit`, `HydraApi`.

- [ ] **Step 1: Write the failing API test**

`HydraApiTest.kt`:

```kotlin
package com.hydra.android.core.network

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class HydraApiTest {
    private lateinit var server: MockWebServer
    private lateinit var api: HydraApi

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
        api = Retrofit.Builder()
            .baseUrl(server.url("/"))
            .client(OkHttpClient())
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(HydraApi::class.java)
    }

    @After fun tearDown() { server.shutdown() }

    @Test
    fun `listDevices sends refresh and include_mobile only when set`() = runTest {
        server.enqueue(MockResponse().setBody("[]"))
        api.listDevices(refresh = null, includeMobile = null)
        assertEquals("/api/devices", server.takeRequest().path)

        server.enqueue(MockResponse().setBody("[]"))
        api.listDevices(refresh = true, includeMobile = false)
        val path = server.takeRequest().path!!
        assertTrue(path.contains("refresh=true"))
        assertTrue(path.contains("include_mobile=false"))
    }

    @Test
    fun `health decodes status and version`() = runTest {
        server.enqueue(MockResponse().setBody("""{"status":"healthy","version":"1.2.3"}"""))
        val health = api.health()
        assertEquals("healthy", health.status)
        assertEquals("1.2.3", health.version)
    }

    @Test
    fun `chat decodes a plan response`() = runTest {
        server.enqueue(MockResponse().setBody(
            """{"type":"plan","message":"run uptime",
                "plan":{"intent":"check uptime",
                "actions":[{"type":"exec","args":{"deviceId":"d1","command":"uptime"}}]}}"""
        ))
        val resp = api.chat(
            com.hydra.android.core.model.ChatRequest(history = emptyList(), message = "hi")
        )
        assertEquals("plan", resp.type)
        assertEquals("check uptime", resp.plan?.intent)
        assertEquals("command=uptime deviceId=d1", resp.plan?.actions?.first()?.argsSummary)
    }

    @Test
    fun `snapshot decodes a device-keyed metrics map`() = runTest {
        server.enqueue(MockResponse().setBody(
            """{"collectedAt":"2026-09-02T10:00:00Z","devices":{"d1":{
                "deviceId":"d1",
                "cpu":{"usagePercent":12.5,"cores":8,"modelName":"M2","loadAvg1":1.0,"loadAvg5":1.0,"loadAvg15":1.0},
                "memory":{"total":100,"used":50,"free":50,"available":50,"usagePercent":50.0,"swapTotal":0,"swapUsed":0,"swapFree":0},
                "disk":{"partitions":null},
                "collectedAt":"2026-09-02T10:00:00Z"}}}"""
        ))
        val snap = api.metricsSnapshot()
        assertEquals(12.5, snap.devices.getValue("d1").cpu.usagePercent, 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:network:testDebugUnitTest --tests '*HydraApiTest*'
```

Expected: FAIL — unresolved reference `HydraApi`.

- [ ] **Step 3: Write `HydraApi`**

```kotlin
package com.hydra.android.core.network

import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentExecuteResponse
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatResponse
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.GpuMonitorResponse
import com.hydra.android.core.model.HealthResponse
import com.hydra.android.core.model.MetricsSnapshotResponse
import com.hydra.android.core.model.NagaTask
import com.hydra.android.core.model.Orch
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Query

/** The eight endpoints v1 uses. See the spec's endpoint table. */
interface HydraApi {
    @GET("health")
    suspend fun health(): HealthResponse

    /** Null query params are omitted by Retrofit, matching iOS's conditional query building. */
    @GET("api/devices")
    suspend fun listDevices(
        @Query("refresh") refresh: Boolean? = null,
        @Query("include_mobile") includeMobile: Boolean? = null,
    ): List<Device>

    @GET("api/orchs")
    suspend fun listOrchs(): List<Orch>

    @GET("api/tasks")
    suspend fun listTasks(): List<NagaTask>

    @GET("api/monitor/gpu")
    suspend fun gpuMonitor(): GpuMonitorResponse

    @GET("api/monitor/snapshot")
    suspend fun metricsSnapshot(): MetricsSnapshotResponse

    @POST("api/agent/chat")
    suspend fun chat(@Body body: ChatRequest): ChatResponse

    @POST("api/agent/execute")
    suspend fun execute(@Body body: AgentExecuteRequest): AgentExecuteResponse
}
```

- [ ] **Step 4: Write `NetworkModule`**

```kotlin
package com.hydra.android.core.network

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    @Provides @Singleton
    fun provideOkHttp(config: ServerConfigProvider): OkHttpClient =
        OkHttpClient.Builder()
            .addInterceptor(BaseUrlInterceptor(config))
            .addInterceptor(AuthInterceptor(config))
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()

    /**
     * The base URL here is a placeholder that BaseUrlInterceptor overwrites on
     * every request. Retrofit still requires a syntactically valid, absolute
     * URL ending in '/', so this constant must stay well-formed.
     */
    @Provides @Singleton
    fun provideRetrofit(client: OkHttpClient, json: Json): Retrofit =
        Retrofit.Builder()
            .baseUrl("http://placeholder.invalid/")
            .client(client)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()

    @Provides @Singleton
    fun provideHydraApi(retrofit: Retrofit): HydraApi = retrofit.create(HydraApi::class.java)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:network:testDebugUnitTest
```

Expected: PASS, 15 tests total in the module.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/network
git commit -m "feat(android): Retrofit HydraApi 8개 엔드포인트 + Hilt 네트워크 모듈"
```

---

### Task 5: `:core:data` — settings and Keystore-backed secret store

**Files:**
- Modify: `android/core/data/build.gradle.kts`
- Create: `.../core/data/SettingsRepository.kt`, `SecureStore.kt`, `SettingsServerConfigProvider.kt`, `DataModule.kt`
- Test: `android/core/data/src/test/kotlin/com/hydra/android/core/data/SettingsServerConfigProviderTest.kt`

**Interfaces:**
- Consumes: `ServerConfigProvider` (Task 3).
- Produces:
  - `class SettingsRepository` with `val serverUrl: Flow<String>`, `val aiInstruction: Flow<String>`, `val hideMobileDevices: Flow<Boolean>`, and `suspend fun setServerUrl/setAiInstruction/setHideMobileDevices`
  - `interface SecureStore { fun getApiKey(): String?; fun setApiKey(value: String) }` with `KeystoreSecureStore` implementation
  - `class SettingsServerConfigProvider : ServerConfigProvider`
  - Hilt `DataModule` binding `ServerConfigProvider` and `SecureStore`

- [ ] **Step 1: Add module dependencies**

```kotlin
plugins {
    id("hydra.android.library")
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android { namespace = "com.hydra.android.core.data" }
dependencies {
    api(project(":core:model"))
    api(project(":core:network"))
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
```

- [ ] **Step 2: Write the failing config-provider test**

`SettingsServerConfigProvider` must read the *current* value synchronously — OkHttp interceptors are not suspending. It caches the latest emission from the settings flows.

```kotlin
package com.hydra.android.core.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SettingsServerConfigProviderTest {

    private class FakeSecureStore(private var key: String?) : SecureStore {
        override fun getApiKey() = key
        override fun setApiKey(value: String) { key = value }
    }

    @Test
    fun `defaults to localhost before any settings emission arrives`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        assertEquals("http://localhost:8080", provider.baseUrl())
    }

    @Test
    fun `reflects the latest cached server url`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("http://100.1.2.3:8080")
        assertEquals("http://100.1.2.3:8080", provider.baseUrl())
    }

    @Test
    fun `blank server url falls back to the default rather than breaking requests`() {
        val provider = SettingsServerConfigProvider(FakeSecureStore(null))
        provider.updateServerUrl("   ")
        assertEquals("http://localhost:8080", provider.baseUrl())
    }

    @Test
    fun `reads the api key from the secure store on every call`() {
        val store = FakeSecureStore(null)
        val provider = SettingsServerConfigProvider(store)
        assertNull(provider.apiKey())
        store.setApiKey("k1")
        assertEquals("k1", provider.apiKey())
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest
```

Expected: FAIL — unresolved references `SettingsServerConfigProvider`, `SecureStore`.

- [ ] **Step 4: Write `SecureStore`**

```kotlin
package com.hydra.android.core.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.security.KeyStore

interface SecureStore {
    fun getApiKey(): String?
    fun setApiKey(value: String)
}

/**
 * The iOS client keeps secrets in the Keychain via CredentialStore. v1 has
 * exactly one secret (the server API key), and androidx.security-crypto is
 * deprecated in Jetpack, so this wraps Android Keystore AES/GCM directly and
 * stores the ciphertext in a plain SharedPreferences file.
 *
 * Layout: "<base64 iv>:<base64 ciphertext>".
 */
class KeystoreSecureStore(context: Context) : SecureStore {

    private val prefs = context.getSharedPreferences("hydra_secure", Context.MODE_PRIVATE)

    override fun getApiKey(): String? {
        val stored = prefs.getString(KEY_API, null) ?: return null
        val parts = stored.split(':')
        if (parts.size != 2) return null
        return runCatching {
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val cipherText = Base64.decode(parts[1], Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        }.getOrNull()
    }

    override fun setApiKey(value: String) {
        if (value.isEmpty()) {
            prefs.edit().remove(KEY_API).apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val encoded = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipherText, Base64.NO_WRAP)
        prefs.edit().putString(KEY_API, encoded).apply()
    }

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "hydra_api_key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val KEY_API = "server_api_key"
    }
}
```

- [ ] **Step 5: Write `SettingsRepository` and `SettingsServerConfigProvider`**

```kotlin
package com.hydra.android.core.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore("hydra_settings")

class SettingsRepository(private val context: Context) {

    val serverUrl: Flow<String> = context.dataStore.data.map {
        it[SERVER_URL] ?: DEFAULT_SERVER_URL
    }
    val aiInstruction: Flow<String> = context.dataStore.data.map { it[AI_INSTRUCTION] ?: "" }
    val hideMobileDevices: Flow<Boolean> = context.dataStore.data.map {
        it[HIDE_MOBILE] ?: false
    }

    suspend fun setServerUrl(value: String) {
        context.dataStore.edit { it[SERVER_URL] = value }
    }

    suspend fun setAiInstruction(value: String) {
        context.dataStore.edit { it[AI_INSTRUCTION] = value }
    }

    suspend fun setHideMobileDevices(value: Boolean) {
        context.dataStore.edit { it[HIDE_MOBILE] = value }
    }

    companion object {
        const val DEFAULT_SERVER_URL = "http://localhost:8080"
        private val SERVER_URL = stringPreferencesKey("serverUrl")
        private val AI_INSTRUCTION = stringPreferencesKey("aiInstruction")
        private val HIDE_MOBILE = booleanPreferencesKey("hideMobileDevices")
    }
}
```

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.network.ServerConfigProvider
import java.util.concurrent.atomic.AtomicReference

/**
 * OkHttp interceptors are not suspending, so they cannot await a DataStore
 * flow. This holds the last observed server URL in an atomic cell that a
 * long-lived collector (started in DataModule) keeps current.
 */
class SettingsServerConfigProvider(
    private val secureStore: SecureStore,
) : ServerConfigProvider {

    private val cached = AtomicReference(SettingsRepository.DEFAULT_SERVER_URL)

    fun updateServerUrl(value: String) {
        cached.set(value.trim().ifEmpty { SettingsRepository.DEFAULT_SERVER_URL })
    }

    override fun baseUrl(): String = cached.get()

    override fun apiKey(): String? = secureStore.getApiKey()
}
```

- [ ] **Step 6: Write `DataModule`**

```kotlin
package com.hydra.android.core.data

import android.content.Context
import com.hydra.android.core.network.ServerConfigProvider
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collectLatest
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object DataModule {

    @Provides @Singleton
    fun provideSecureStore(@ApplicationContext context: Context): SecureStore =
        KeystoreSecureStore(context)

    @Provides @Singleton
    fun provideSettingsRepository(@ApplicationContext context: Context) =
        SettingsRepository(context)

    @Provides @Singleton
    fun provideServerConfigProvider(
        secureStore: SecureStore,
        settings: SettingsRepository,
    ): ServerConfigProvider {
        val provider = SettingsServerConfigProvider(secureStore)
        // Keeps the atomic cell current for the non-suspending interceptors.
        CoroutineScope(SupervisorJob()).launch {
            settings.serverUrl.collectLatest { provider.updateServerUrl(it) }
        }
        return provider
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest
```

Expected: PASS, 4 tests.

- [ ] **Step 8: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data
git commit -m "feat(android): DataStore 설정 + Keystore AES/GCM API 키 저장"
```

---

### Task 6: `:core:data` — `DashboardRepository` with partial-failure semantics

This is the task that encodes the core/auxiliary asymmetry. Get it wrong and a GPU-less server shows a fully failed dashboard.

**Files:**
- Create: `.../core/data/DashboardRepository.kt`, `DashboardSnapshot.kt`
- Test: `android/core/data/src/test/kotlin/com/hydra/android/core/data/DashboardRepositoryTest.kt`

**Interfaces:**
- Consumes: `HydraApi` (Task 4), `apiCall`/`ApiException` (Task 3), models (Task 2), `SettingsRepository` (Task 5).
- Produces:
  - `data class DashboardSnapshot(val serverStatus: ServerStatus, val serverVersion: String, val devices: List<Device>, val orchs: List<Orch>, val tasks: List<NagaTask>, val gpuNodes: List<GpuNodeStatus>, val metricsByDevice: Map<String, DeviceMetrics>, val error: String?)`
  - `enum class ServerStatus { CONNECTED, DISCONNECTED, UNKNOWN }`
  - `class DashboardRepository { suspend fun load(force: Boolean, hideMobile: Boolean): DashboardSnapshot }`

- [ ] **Step 1: Write the failing repository tests**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.*
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.test.runTest
import kotlinx.datetime.Instant
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response
import java.io.IOException

private val T0 = Instant.parse("2026-09-02T10:00:00Z")

private fun device(id: String, status: String = "online") = Device(
    id = id, name = "", hostname = id, status = status, lastSeen = T0,
)

private fun orch(id: String, status: String = "running") = Orch(
    id = id, name = id, status = status, createdAt = T0, updatedAt = T0,
)

/** Every call fails unless a value is supplied — makes each test state its own preconditions. */
private open class FakeApi(
    val health: () -> HealthResponse = { throw IOException("down") },
    val devices: () -> List<Device> = { throw IOException("down") },
    val orchs: () -> List<Orch> = { throw IOException("down") },
    val tasks: () -> List<NagaTask> = { throw IOException("down") },
    val gpu: () -> GpuMonitorResponse = { throw IOException("down") },
    val snapshot: () -> MetricsSnapshotResponse = { throw IOException("down") },
) : HydraApi {
    var lastRefresh: Boolean? = null
    var lastIncludeMobile: Boolean? = null
    override suspend fun health() = health.invoke()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?): List<Device> {
        lastRefresh = refresh; lastIncludeMobile = includeMobile; return devices.invoke()
    }
    override suspend fun listOrchs() = orchs.invoke()
    override suspend fun listTasks() = tasks.invoke()
    override suspend fun gpuMonitor() = gpu.invoke()
    override suspend fun metricsSnapshot() = snapshot.invoke()
    override suspend fun chat(body: ChatRequest) = throw UnsupportedOperationException()
    override suspend fun execute(body: AgentExecuteRequest) = throw UnsupportedOperationException()
}

class DashboardRepositoryTest {

    private fun repo(api: HydraApi) = DashboardRepository(api)

    @Test
    fun `auxiliary failures leave their sections empty without setting error`() = runTest {
        // A server with no GPU nodes must not render the whole dashboard as failed.
        // Mirrors loadGPU()'s empty catch in DashboardViewModel.swift:360-367.
        val api = FakeApi(
            health = { HealthResponse("healthy", "1.0") },
            devices = { listOf(device("d1")) },
            orchs = { listOf(orch("o1")) },
        )
        val snap = repo(api).load(force = false, hideMobile = false)

        assertNull(snap.error)
        assertEquals(1, snap.devices.size)
        assertEquals(1, snap.orchs.size)
        assertTrue(snap.gpuNodes.isEmpty())
        assertTrue(snap.tasks.isEmpty())
        assertTrue(snap.metricsByDevice.isEmpty())
    }

    @Test
    fun `device failure surfaces an error`() = runTest {
        val api = FakeApi(
            health = { HealthResponse("healthy", "1.0") },
            orchs = { listOf(orch("o1")) },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertNotNull(snap.error)
        assertEquals("서버에 연결할 수 없습니다", snap.error)
    }

    @Test
    fun `orch failure surfaces the server error body`() = runTest {
        val api = FakeApi(
            health = { HealthResponse("healthy", "1.0") },
            devices = { listOf(device("d1")) },
            orchs = {
                throw HttpException(Response.error<Any>(
                    500, """{"error":"orch store unavailable"}"""
                        .toResponseBody("application/json".toMediaType())))
            },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertEquals("orch store unavailable", snap.error)
    }

    @Test
    fun `health failure sets disconnected instead of an error banner`() = runTest {
        val api = FakeApi(
            devices = { listOf(device("d1")) },
            orchs = { listOf(orch("o1")) },
        )
        val snap = repo(api).load(force = false, hideMobile = false)
        assertEquals(ServerStatus.DISCONNECTED, snap.serverStatus)
        assertNull(snap.error)
    }

    @Test
    fun `unhealthy status reads as disconnected`() = runTest {
        val api = FakeApi(
            health = { HealthResponse("degraded", "1.0") },
            devices = { emptyList() }, orchs = { emptyList() },
        )
        assertEquals(
            ServerStatus.DISCONNECTED,
            repo(api).load(force = false, hideMobile = false).serverStatus
        )
    }

    @Test
    fun `force refresh passes refresh true and hideMobile passes include_mobile false`() = runTest {
        val api = FakeApi(
            health = { HealthResponse("healthy", "1.0") },
            devices = { emptyList() }, orchs = { emptyList() },
        )
        repo(api).load(force = true, hideMobile = true)
        assertEquals(true, api.lastRefresh)
        assertEquals(false, api.lastIncludeMobile)
    }

    @Test
    fun `unforced load with visible mobiles omits both query params`() = runTest {
        val api = FakeApi(
            health = { HealthResponse("healthy", "1.0") },
            devices = { emptyList() }, orchs = { emptyList() },
        )
        repo(api).load(force = false, hideMobile = false)
        assertNull(api.lastRefresh)
        assertNull(api.lastIncludeMobile)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest --tests '*DashboardRepositoryTest*'
```

Expected: FAIL — unresolved references `DashboardRepository`, `DashboardSnapshot`, `ServerStatus`.

- [ ] **Step 3: Write `DashboardSnapshot`**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.Device
import com.hydra.android.core.model.DeviceMetrics
import com.hydra.android.core.model.GpuNodeStatus
import com.hydra.android.core.model.NagaTask
import com.hydra.android.core.model.Orch

enum class ServerStatus { CONNECTED, DISCONNECTED, UNKNOWN }

/** Combined health used by the top banner, mirroring iOS SystemHealth. */
enum class SystemHealth { HEALTHY, DEGRADED, DOWN, UNKNOWN }

data class DashboardSnapshot(
    val serverStatus: ServerStatus = ServerStatus.UNKNOWN,
    val serverVersion: String = "",
    val devices: List<Device> = emptyList(),
    val orchs: List<Orch> = emptyList(),
    val tasks: List<NagaTask> = emptyList(),
    val gpuNodes: List<GpuNodeStatus> = emptyList(),
    val metricsByDevice: Map<String, DeviceMetrics> = emptyMap(),
    val error: String? = null,
) {
    val onlineDevices: List<Device> get() = devices.filter { it.isOnline }
    val offlineDevices: List<Device> get() = devices.filter { !it.isOnline }
    val gpuDevices: List<Device> get() = devices.filter { it.hasGpu }
    val totalGpus: Int get() = gpuDevices.sumOf { it.gpuCount }
    val runningOrchs: List<Orch> get() = orchs.filter { it.isRunning }
    val runningTasks: List<NagaTask> get() = tasks.filter { it.isRunning }
    val recentTasks: List<NagaTask>
        get() = tasks.sortedByDescending { it.sortInstant }.take(10)

    private val allGpus get() = gpuNodes.flatMap { it.gpus.orEmpty() }
    val avgGpuUtilization: Double
        get() = allGpus.takeIf { it.isNotEmpty() }
            ?.sumOf { it.utilizationPercent }?.div(allGpus.size) ?: 0.0
    val totalVramUsedGb: Double get() = allGpus.sumOf { it.memoryUsedMB }.toDouble() / 1024
    val totalVramTotalGb: Double get() = allGpus.sumOf { it.memoryTotalMB }.toDouble() / 1024

    val systemHealth: SystemHealth
        get() = when (serverStatus) {
            ServerStatus.UNKNOWN -> SystemHealth.UNKNOWN
            ServerStatus.DISCONNECTED -> SystemHealth.DOWN
            ServerStatus.CONNECTED ->
                if (offlineDevices.isEmpty()) SystemHealth.HEALTHY else SystemHealth.DEGRADED
        }
}
```

- [ ] **Step 4: Write `DashboardRepository`**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Merges the five dashboard sources. The core/auxiliary asymmetry is
 * deliberate and mirrors iOS DashboardViewModel.load():
 *
 *   - devices + orchs: fetched concurrently; a failure sets `error`.
 *   - gpu, metrics, tasks: failures are swallowed and leave the section empty
 *     (iOS comments this "GPU monitoring is optional").
 *   - /health never sets `error`; it only drives the status banner.
 */
@Singleton
class DashboardRepository @Inject constructor(
    private val api: HydraApi,
) {
    suspend fun load(force: Boolean, hideMobile: Boolean): DashboardSnapshot = coroutineScope {
        val health = apiCall { api.health() }

        // Null query params are omitted, matching iOS's conditional query build.
        val devicesDeferred = async {
            apiCall {
                api.listDevices(
                    refresh = if (force) true else null,
                    includeMobile = if (hideMobile) false else null,
                )
            }
        }
        val orchsDeferred = async { apiCall { api.listOrchs() } }
        val gpuDeferred = async { apiCall { api.gpuMonitor() } }
        val tasksDeferred = async { apiCall { api.listTasks() } }
        val metricsDeferred = async { apiCall { api.metricsSnapshot() } }

        val devices = devicesDeferred.await()
        val orchs = orchsDeferred.await()

        DashboardSnapshot(
            serverStatus = health.fold(
                onSuccess = {
                    if (it.status == "healthy") ServerStatus.CONNECTED
                    else ServerStatus.DISCONNECTED
                },
                onFailure = { ServerStatus.DISCONNECTED },
            ),
            serverVersion = health.getOrNull()?.version.orEmpty(),
            devices = devices.getOrDefault(emptyList()),
            orchs = orchs.getOrDefault(emptyList()),
            gpuNodes = gpuDeferred.await().getOrNull()?.nodes.orEmpty(),
            tasks = tasksDeferred.await().getOrDefault(emptyList()),
            metricsByDevice = metricsDeferred.await().getOrNull()?.devices.orEmpty(),
            error = devices.exceptionOrNull()?.message ?: orchs.exceptionOrNull()?.message,
        )
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest
```

Expected: PASS, 11 tests in the module.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data
git commit -m "feat(android): 대시보드 저장소 — 핵심/보조 fetch 부분 실패 처리"
```

---

### Task 7: `:core:data` — `ChatRepository`

**Files:**
- Create: `.../core/data/ChatRepository.kt`
- Test: `android/core/data/src/test/kotlin/com/hydra/android/core/data/ChatRepositoryTest.kt`

**Interfaces:**
- Consumes: `HydraApi`, `apiCall`, chat models.
- Produces: `class ChatRepository { suspend fun send(history: List<ChatTurn>, message: String, instruction: String?): Result<ChatResponse>; suspend fun execute(plan: AgentPlan): Result<AgentExecuteResponse> }` and `const val SERVER_HISTORY_CAP = 20`.

- [ ] **Step 1: Write the failing tests**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.*
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.IOException

private class ChatFakeApi(
    private val response: () -> ChatResponse = { ChatResponse("ask", "hi") },
    private val executeResponse: () -> AgentExecuteResponse = { AgentExecuteResponse() },
) : HydraApi {
    var lastRequest: ChatRequest? = null
    var lastExecute: AgentExecuteRequest? = null
    override suspend fun health() = throw UnsupportedOperationException()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun listOrchs() = throw UnsupportedOperationException()
    override suspend fun listTasks() = throw UnsupportedOperationException()
    override suspend fun gpuMonitor() = throw UnsupportedOperationException()
    override suspend fun metricsSnapshot() = throw UnsupportedOperationException()
    override suspend fun chat(body: ChatRequest): ChatResponse {
        lastRequest = body; return response.invoke()
    }
    override suspend fun execute(body: AgentExecuteRequest): AgentExecuteResponse {
        lastExecute = body; return executeResponse.invoke()
    }
}

class ChatRepositoryTest {

    @Test
    fun `outbound history is capped at the last 20 turns`() = runTest {
        val api = ChatFakeApi()
        val history = (1..30).map { ChatTurn(role = "user", content = "m$it") }
        ChatRepository(api).send(history, "next", instruction = null)

        val sent = api.lastRequest!!.history
        assertEquals(20, sent.size)
        assertEquals("m11", sent.first().content)
        assertEquals("m30", sent.last().content)
    }

    @Test
    fun `a short history is sent whole`() = runTest {
        val api = ChatFakeApi()
        ChatRepository(api).send(
            listOf(ChatTurn(role = "user", content = "only")), "next", instruction = null
        )
        assertEquals(1, api.lastRequest!!.history.size)
    }

    @Test
    fun `a blank instruction is sent as null rather than an empty string`() = runTest {
        val api = ChatFakeApi()
        ChatRepository(api).send(emptyList(), "hi", instruction = "   ")
        assertNull(api.lastRequest!!.instruction)
    }

    @Test
    fun `a real instruction is attached`() = runTest {
        val api = ChatFakeApi()
        ChatRepository(api).send(emptyList(), "hi", instruction = "be terse")
        assertEquals("be terse", api.lastRequest!!.instruction)
    }

    @Test
    fun `a network failure comes back as a failed Result`() = runTest {
        val api = ChatFakeApi(response = { throw IOException("down") })
        val result = ChatRepository(api).send(emptyList(), "hi", instruction = null)
        assertEquals("서버에 연결할 수 없습니다", result.exceptionOrNull()?.message)
    }

    @Test
    fun `execute forwards the plan verbatim`() = runTest {
        val api = ChatFakeApi()
        val plan = AgentPlan("check", listOf(AgentAction("exec", kotlinx.serialization.json.JsonObject(emptyMap()))))
        ChatRepository(api).execute(plan)
        assertEquals("check", api.lastExecute!!.plan.intent)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest --tests '*ChatRepositoryTest*'
```

Expected: FAIL — unresolved reference `ChatRepository`.

- [ ] **Step 3: Write `ChatRepository`**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentExecuteResponse
import com.hydra.android.core.model.AgentPlan
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatResponse
import com.hydra.android.core.model.ChatTurn
import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import javax.inject.Inject
import javax.inject.Singleton

/** History sent to the server is capped; the UI keeps the full list. */
const val SERVER_HISTORY_CAP = 20

@Singleton
class ChatRepository @Inject constructor(private val api: HydraApi) {

    suspend fun send(
        history: List<ChatTurn>,
        message: String,
        instruction: String?,
    ): Result<ChatResponse> = apiCall {
        api.chat(
            ChatRequest(
                history = history.takeLast(SERVER_HISTORY_CAP),
                message = message,
                instruction = instruction?.trim()?.takeIf { it.isNotEmpty() },
            )
        )
    }

    suspend fun execute(plan: AgentPlan): Result<AgentExecuteResponse> =
        apiCall { api.execute(AgentExecuteRequest(plan)) }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest
```

Expected: PASS, 17 tests in the module.

- [ ] **Step 5: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data
git commit -m "feat(android): Chat 저장소 — 히스토리 20턴 캡 + plan 실행"
```

---

### Task 8: `:core:designsystem` — theme and shared card

**Files:**
- Modify: `android/core/designsystem/build.gradle.kts`
- Create: `.../core/designsystem/Color.kt`, `Theme.kt`, `HydraCard.kt`, `StatusDot.kt`

**Interfaces:**
- Consumes: nothing.
- Produces: `@Composable fun HydraTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit)`, `@Composable fun HydraCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit)`, `@Composable fun StatusDot(online: Boolean, modifier: Modifier = Modifier)`, and the accent colors `HydraBlue`, `HydraPurple`, `HydraGreen`, `HydraOrange`, `HydraRed`.

- [ ] **Step 1: Add module dependencies**

```kotlin
plugins {
    id("hydra.android.library")
    id("hydra.android.compose")
}
android { namespace = "com.hydra.android.core.designsystem" }
dependencies {
    implementation(libs.compose.material.icons.extended)
}
```

- [ ] **Step 2: Write `Color.kt`**

The four summary-card accents come straight from `DashboardScreen.swift:16-47` (`.blue` Devices, `.purple` GPU Nodes, `.green` Orchs, `.orange` Tasks).

```kotlin
package com.hydra.android.core.designsystem

import androidx.compose.ui.graphics.Color

val HydraBlue = Color(0xFF0A84FF)
val HydraPurple = Color(0xFFBF5AF2)
val HydraGreen = Color(0xFF30D158)
val HydraOrange = Color(0xFFFF9F0A)
val HydraRed = Color(0xFFFF453A)
```

- [ ] **Step 3: Write `Theme.kt`**

```kotlin
package com.hydra.android.core.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val DarkColors = darkColorScheme(primary = HydraBlue, tertiary = HydraPurple)
private val LightColors = lightColorScheme(primary = HydraBlue, tertiary = HydraPurple)

@Composable
fun HydraTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
```

Dynamic color is deliberately not used: the dashboard encodes meaning in the four accent colors, and Material You would repaint them per wallpaper.

- [ ] **Step 4: Write `HydraCard.kt` and `StatusDot.kt`**

```kotlin
package com.hydra.android.core.designsystem

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** The single card surface every dashboard section sits on. */
@Composable
fun HydraCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(modifier = modifier, elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)) {
        Column(modifier = Modifier.padding(12.dp), content = content)
    }
}
```

```kotlin
package com.hydra.android.core.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun StatusDot(online: Boolean, modifier: Modifier = Modifier) {
    androidx.compose.foundation.layout.Box(
        modifier
            .size(8.dp)
            .background(
                color = if (online) HydraGreen else MaterialTheme.colorScheme.error,
                shape = CircleShape,
            )
    )
}
```

- [ ] **Step 5: Verify it compiles**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:designsystem:assembleDebug
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/designsystem
git commit -m "feat(android): 디자인 시스템 — 테마/카드/상태 표시"
```

---

### Task 9: `:feature:settings`

**Files:**
- Modify: `android/feature/settings/build.gradle.kts`
- Create: `.../feature/settings/SettingsViewModel.kt`, `SettingsScreen.kt`, `SettingsNavigation.kt`
- Test: `android/feature/settings/src/test/kotlin/com/hydra/android/feature/settings/SettingsViewModelTest.kt`

**Interfaces:**
- Consumes: `SettingsRepository`, `SecureStore` (Task 5); `HydraTheme` (Task 8).
- Produces: `fun NavGraphBuilder.settingsScreen()` and `const val SETTINGS_ROUTE = "settings"`.

- [ ] **Step 1: Add module dependencies**

```kotlin
plugins {
    id("hydra.android.library")
    id("hydra.android.compose")
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}
android { namespace = "com.hydra.android.feature.settings" }
dependencies {
    implementation(project(":core:data"))
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.hilt.android)
    implementation(libs.hilt.navigation.compose)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
    testImplementation(libs.turbine)
    testImplementation(libs.kotlinx.coroutines.test)
}
```

- [ ] **Step 2: Write the failing ViewModel test**

```kotlin
package com.hydra.android.feature.settings

import app.cash.turbine.test
import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

private class FakeSecureStore : SecureStore {
    var key: String? = null
    override fun getApiKey() = key
    override fun setApiKey(value: String) { key = value.ifEmpty { null } }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `exposes stored settings and the masked key presence`() = runTest {
        val store = FakeSecureStore().apply { key = "secret" }
        val vm = SettingsViewModel(FakeSettings(serverUrl = "http://1.2.3.4:8080"), store)

        vm.state.test {
            val s = awaitItem()
            assertEquals("http://1.2.3.4:8080", s.serverUrl)
            assertEquals("secret", s.apiKey)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `saving an api key writes through to the secure store`() = runTest {
        val store = FakeSecureStore()
        val vm = SettingsViewModel(FakeSettings(), store)
        vm.onApiKeyChange("k9")
        assertEquals("k9", store.key)
    }

    @Test
    fun `clearing the api key removes it from the secure store`() = runTest {
        val store = FakeSecureStore().apply { key = "old" }
        val vm = SettingsViewModel(FakeSettings(), store)
        vm.onApiKeyChange("")
        assertEquals(null, store.key)
    }
}
```

`FakeSettings` is a test double that must be added in the same file — `SettingsRepository` is a concrete class over DataStore, so extract an interface for it in Step 4 rather than faking Android's DataStore:

```kotlin
private class FakeSettings(
    serverUrl: String = SettingsRepository.DEFAULT_SERVER_URL,
    aiInstruction: String = "",
    hideMobile: Boolean = false,
) : SettingsSource {
    override val serverUrl = MutableStateFlow(serverUrl)
    override val aiInstruction = MutableStateFlow(aiInstruction)
    override val hideMobileDevices = MutableStateFlow(hideMobile)
    override suspend fun setServerUrl(value: String) { this.serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { this.aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:settings:testDebugUnitTest
```

Expected: FAIL — unresolved references `SettingsViewModel`, `SettingsSource`.

- [ ] **Step 4: Extract `SettingsSource` in `:core:data`**

Add to `android/core/data/src/main/kotlin/com/hydra/android/core/data/SettingsRepository.kt`:

```kotlin
/**
 * The read/write surface ViewModels depend on. Exists so tests can substitute
 * a plain StateFlow-backed fake instead of standing up Android's DataStore.
 */
interface SettingsSource {
    val serverUrl: Flow<String>
    val aiInstruction: Flow<String>
    val hideMobileDevices: Flow<Boolean>
    suspend fun setServerUrl(value: String)
    suspend fun setAiInstruction(value: String)
    suspend fun setHideMobileDevices(value: Boolean)
}
```

Change `class SettingsRepository(private val context: Context)` to `class SettingsRepository(private val context: Context) : SettingsSource`, and mark its six members `override`. In `DataModule`, add a binding so `SettingsSource` resolves:

```kotlin
@Provides @Singleton
fun provideSettingsSource(repository: SettingsRepository): SettingsSource = repository
```

- [ ] **Step 5: Write `SettingsViewModel`**

```kotlin
package com.hydra.android.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.SecureStore
import com.hydra.android.core.data.SettingsSource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class SettingsUiState(
    val serverUrl: String = "",
    val apiKey: String = "",
    val aiInstruction: String = "",
    val hideMobileDevices: Boolean = false,
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settings: SettingsSource,
    private val secureStore: SecureStore,
) : ViewModel() {

    // The key is not a Flow — it lives in the Keystore, read once and then
    // mirrored here so the text field stays a controlled component.
    private val apiKey = MutableStateFlow(secureStore.getApiKey().orEmpty())

    val state: StateFlow<SettingsUiState> = combine(
        settings.serverUrl, apiKey, settings.aiInstruction, settings.hideMobileDevices,
    ) { url, key, instruction, hideMobile ->
        SettingsUiState(url, key, instruction, hideMobile)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SettingsUiState())

    fun onServerUrlChange(value: String) {
        viewModelScope.launch { settings.setServerUrl(value) }
    }

    fun onApiKeyChange(value: String) {
        apiKey.value = value
        secureStore.setApiKey(value)
    }

    fun onAiInstructionChange(value: String) {
        viewModelScope.launch { settings.setAiInstruction(value) }
    }

    fun onHideMobileChange(value: Boolean) {
        viewModelScope.launch { settings.setHideMobileDevices(value) }
    }
}
```

- [ ] **Step 6: Write `SettingsScreen` and its navigation entry**

`SettingsScreen.kt` renders a single scrolling column of four controls, mirroring `HydraiOS/Screens/SettingsScreen.swift` minus the SSH section:

```kotlin
package com.hydra.android.feature.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(viewModel: SettingsViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    Scaffold(topBar = { TopAppBar(title = { Text("설정") }) }) { padding ->
        Column(
            Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("서버", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(
                value = state.serverUrl,
                onValueChange = viewModel::onServerUrlChange,
                label = { Text("http://<host>:8080") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    capitalization = KeyboardCapitalization.None,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.apiKey,
                onValueChange = viewModel::onApiKeyChange,
                label = { Text("API 키") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    capitalization = KeyboardCapitalization.None,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            HorizontalDivider()

            Text("AI", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(
                value = state.aiInstruction,
                onValueChange = viewModel::onAiInstructionChange,
                label = { Text("AI에게 전달할 지침") },
                minLines = 3,
                maxLines = 8,
                modifier = Modifier.fillMaxWidth(),
            )

            HorizontalDivider()

            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("모바일 디바이스 숨기기")
                Switch(
                    checked = state.hideMobileDevices,
                    onCheckedChange = viewModel::onHideMobileChange,
                )
            }
        }
    }
}
```

`SettingsNavigation.kt`:

```kotlin
package com.hydra.android.feature.settings

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val SETTINGS_ROUTE = "settings"

fun NavGraphBuilder.settingsScreen() {
    composable(SETTINGS_ROUTE) { SettingsScreen() }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest :feature:settings:testDebugUnitTest
```

Expected: PASS — `:core:data` still 17, `:feature:settings` 3.

- [ ] **Step 8: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data android/feature/settings
git commit -m "feat(android): 설정 화면 — 서버/API 키/AI 지침/모바일 숨김"
```

---

### Task 10: `:feature:dashboard` — ViewModel with subscription-driven polling

**Files:**
- Modify: `android/feature/dashboard/build.gradle.kts`
- Create: `.../feature/dashboard/DashboardViewModel.kt`
- Test: `android/feature/dashboard/src/test/kotlin/com/hydra/android/feature/dashboard/DashboardViewModelTest.kt`

**Interfaces:**
- Consumes: `DashboardRepository`, `DashboardSnapshot`, `SettingsSource` (Tasks 5-6).
- Produces: `data class DashboardUiState(val snapshot: DashboardSnapshot, val isLoading: Boolean, val lastRefresh: Instant?)`, `class DashboardViewModel` with `val state: StateFlow<DashboardUiState>` and `fun refresh()`.

- [ ] **Step 1: Add module dependencies**

Same block as Task 9's `:feature:settings`, with `android { namespace = "com.hydra.android.feature.dashboard" }` and additionally `implementation(libs.kotlinx.datetime)`.

- [ ] **Step 2: Write the failing ViewModel tests**

```kotlin
package com.hydra.android.feature.dashboard

import app.cash.turbine.test
import com.hydra.android.core.data.DashboardRepository
import com.hydra.android.core.data.DashboardSnapshot
import com.hydra.android.core.data.ServerStatus
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.Device
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val T0 = Instant.parse("2026-09-02T10:00:00Z")

private class FakeSettings : SettingsSource {
    override val serverUrl = MutableStateFlow("http://localhost:8080")
    override val aiInstruction = MutableStateFlow("")
    override val hideMobileDevices = MutableStateFlow(false)
    override suspend fun setServerUrl(value: String) { serverUrl.value = value }
    override suspend fun setAiInstruction(value: String) { aiInstruction.value = value }
    override suspend fun setHideMobileDevices(value: Boolean) { hideMobileDevices.value = value }
}

private class RecordingRepository : DashboardRepository(api = FakeUnusedApi) {
    val forceCalls = mutableListOf<Boolean>()
    var loadCount = 0
    override suspend fun load(force: Boolean, hideMobile: Boolean): DashboardSnapshot {
        forceCalls += force
        loadCount++
        return DashboardSnapshot(
            serverStatus = ServerStatus.CONNECTED,
            devices = listOf(Device(id = "d1", name = "", hostname = "d1",
                status = "online", lastSeen = T0)),
        )
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class DashboardViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `emits a loaded snapshot on first subscription`() = runTest {
        val vm = DashboardViewModel(RecordingRepository(), FakeSettings())
        vm.state.test {
            assertTrue(awaitItem().isLoading)          // initial
            val loaded = awaitItem()
            assertEquals(1, loaded.snapshot.devices.size)
            assertEquals(false, loaded.isLoading)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `polls on the interval while subscribed`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem(); awaitItem()
            advanceTimeBy(5_100)
            awaitItem()
            assertEquals(2, repo.loadCount)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `poll ticks are unforced`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem(); awaitItem()
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(listOf(false), repo.forceCalls)
    }

    @Test
    fun `refresh forces a cache-bypassing load`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem(); awaitItem()
            vm.refresh()
            advanceUntilIdle()
            assertTrue(repo.forceCalls.contains(true))
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `polling stops when nothing is subscribed`() = runTest {
        val repo = RecordingRepository()
        val vm = DashboardViewModel(repo, FakeSettings())
        vm.state.test {
            awaitItem(); awaitItem()
            cancelAndIgnoreRemainingEvents()
        }
        val countAtUnsubscribe = repo.loadCount
        advanceTimeBy(30_000)
        // WhileSubscribed(5_000) keeps it alive briefly, then stops; the count
        // must not keep climbing for the full 30s.
        assertTrue(repo.loadCount - countAtUnsubscribe <= 1)
    }
}
```

`DashboardRepository` must therefore be `open` with an `open suspend fun load`, and `FakeUnusedApi` is an object implementing `HydraApi` whose every member throws `UnsupportedOperationException()` — declare it in the same test file.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:dashboard:testDebugUnitTest
```

Expected: FAIL — unresolved reference `DashboardViewModel`.

- [ ] **Step 4: Make `DashboardRepository` open**

In `android/core/data/.../DashboardRepository.kt`, change the declaration to:

```kotlin
@Singleton
open class DashboardRepository @Inject constructor(
    private val api: HydraApi,
) {
    open suspend fun load(force: Boolean, hideMobile: Boolean): DashboardSnapshot = coroutineScope {
```

- [ ] **Step 5: Write `DashboardViewModel`**

```kotlin
package com.hydra.android.feature.dashboard

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DashboardRepository
import com.hydra.android.core.data.DashboardSnapshot
import com.hydra.android.core.data.SettingsSource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import javax.inject.Inject
import kotlin.time.Duration.Companion.seconds

data class DashboardUiState(
    val snapshot: DashboardSnapshot = DashboardSnapshot(),
    val isLoading: Boolean = true,
    val lastRefresh: Instant? = null,
) {
    /**
     * Full-screen spinner only before anything has arrived; poll ticks must
     * not flash the screen. Mirrors DashboardScreen.swift:76.
     */
    val showBlockingLoader: Boolean
        get() = isLoading && snapshot.devices.isEmpty() && snapshot.orchs.isEmpty()
}

@HiltViewModel
class DashboardViewModel @Inject constructor(
    private val repository: DashboardRepository,
    private val settings: SettingsSource,
) : ViewModel() {

    /** Manual refresh requests, merged into the same load pipeline as the poll. */
    private val forcedRefreshes = MutableSharedFlow<Unit>(
        replay = 0, extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    private val ticks: Flow<Boolean> = flow {
        while (true) {
            emit(false)
            delay(POLL_INTERVAL)
        }
    }

    /**
     * Polling is driven by subscription rather than by explicit start/stop
     * calls. iOS pairs startPolling/stopPolling with .task/.onDisappear
     * (DashboardViewModel.swift:161-173); here, leaving the tab drops the
     * collector and the loop ends on its own.
     */
    val state: StateFlow<DashboardUiState> =
        merge(ticks, forcedRefreshes.map { true })
            .transformLatest { force ->
                val hideMobile = settings.hideMobileDevices.first()
                val snapshot = repository.load(force = force, hideMobile = hideMobile)
                emit(DashboardUiState(snapshot, isLoading = false, lastRefresh = Clock.System.now()))
            }
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(5_000),
                initialValue = DashboardUiState(),
            )

    fun refresh() {
        forcedRefreshes.tryEmit(Unit)
    }

    private companion object {
        val POLL_INTERVAL = 5.seconds
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest :feature:dashboard:testDebugUnitTest
```

Expected: PASS, 5 dashboard tests.

- [ ] **Step 7: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data android/feature/dashboard
git commit -m "feat(android): 대시보드 ViewModel — 구독 기반 5초 폴링"
```

---

### Task 11: `:feature:dashboard` — Compose sections

Each section is its own file so no single file re-creates the 877-line `DashboardScreen.swift`.

**Files:**
- Create: `.../feature/dashboard/DashboardScreen.kt`, `DashboardNavigation.kt`
- Create: `.../feature/dashboard/sections/ServerStatusBanner.kt`, `OfflineAlert.kt`, `SummaryGrid.kt`, `DeviceCards.kt`, `GpuSection.kt`, `RunningOrchsSection.kt`, `RecentTasksSection.kt`
- Test: `android/feature/dashboard/src/androidTest/kotlin/com/hydra/android/feature/dashboard/DashboardScreenTest.kt`

**Interfaces:**
- Consumes: `DashboardUiState` (Task 10); `HydraCard`, `StatusDot`, accent colors (Task 8).
- Produces: `fun NavGraphBuilder.dashboardScreen()` and `const val DASHBOARD_ROUTE = "dashboard"`.

- [ ] **Step 1: Write the section composables**

Each file exposes one `@Composable` taking exactly what it renders — no ViewModel reaches a section.

- `ServerStatusBanner(status: ServerStatus, version: String)` — colored strip; CONNECTED shows `연결됨 · v<version>` on `HydraGreen`, DISCONNECTED shows `서버에 연결할 수 없습니다` on `colorScheme.error`, UNKNOWN shows `확인 중…`.
- `OfflineAlert(devices: List<Device>)` — `HydraCard` listing `shortName`s; the caller renders it only when the list is non-empty.
- `SummaryGrid(state: DashboardUiState)` — a 2-column `LazyVerticalGrid` of four `SummaryCard(title, value, subtitle, icon, accent)`, in exactly this order and with these accents, from `DashboardScreen.swift:19-47`:
  1. `Devices` / `"${online}/${total}"` / `online` / `Icons.Filled.Computer` / `HydraBlue`
  2. `GPU Nodes` / `gpuDevices.size` / `"${totalGpus} GPUs total"` / `Icons.Filled.Memory` / `HydraPurple`
  3. `Orchs` / `orchs.size` / `"${runningOrchs.size} running"` / `Icons.Filled.Dns` / `HydraGreen`
  4. `Tasks` / `runningTasks.size` / `"${tasks.size} total"` / `Icons.AutoMirrored.Filled.List` / `HydraOrange`
- `DeviceCards(devices: List<Device>, metrics: Map<String, DeviceMetrics>)` — one `HydraCard` per device: `StatusDot` + `shortName` + `os`, then CPU/RAM percentage bars pulled from `metrics[device.id]`, and the `gpuModel ?: "-"` line when `hasGpu`. When the device has no metrics entry, render the bars as `—` rather than 0%; a missing sample is not a zero sample.
- `GpuSection(nodes: List<GpuNodeStatus>, avgUtilization: Double, vramUsedGb: Double, vramTotalGb: Double)` — a header row with the aggregate gauge, then per-node rows; a node with `hasError` renders its `error` in `colorScheme.error` instead of gauges. The whole section renders nothing when `nodes` is empty.
- `RunningOrchsSection(orchs: List<Orch>, devices: List<Device>)` — name, mode, and `"${workerCount} workers"`, resolving `coordinatorId` to a device `shortName` when present.
- `RecentTasksSection(tasks: List<NagaTask>, devices: List<Device>)` — status icon per `NagaTask` status (`running`→`PlayCircle`, `completed`→`CheckCircle`, `failed`→`Cancel`, `queued`/`assigned`→`Schedule`, `cancelled`→`RemoveCircle`, else `HelpOutline`), the task `type`, and the resolved device short name.

- [ ] **Step 2: Write `DashboardScreen`**

```kotlin
package com.hydra.android.feature.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.item
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.hydra.android.feature.dashboard.sections.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(viewModel: DashboardViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snapshot = state.snapshot

    Scaffold(topBar = { TopAppBar(title = { Text("대시보드") }) }) { padding ->
        PullToRefreshBox(
            isRefreshing = state.isLoading && !state.showBlockingLoader,
            onRefresh = viewModel::refresh,
            modifier = Modifier.padding(padding),
        ) {
            LazyColumn(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { ServerStatusBanner(snapshot.serverStatus, snapshot.serverVersion) }
                if (snapshot.offlineDevices.isNotEmpty()) {
                    item { OfflineAlert(snapshot.offlineDevices) }
                }
                item { SummaryGrid(state) }
                item { DeviceCards(snapshot.devices, snapshot.metricsByDevice) }
                if (snapshot.gpuNodes.isNotEmpty()) {
                    item {
                        GpuSection(
                            snapshot.gpuNodes, snapshot.avgGpuUtilization,
                            snapshot.totalVramUsedGb, snapshot.totalVramTotalGb,
                        )
                    }
                }
                if (snapshot.runningOrchs.isNotEmpty()) {
                    item { RunningOrchsSection(snapshot.runningOrchs, snapshot.devices) }
                }
                item { RecentTasksSection(snapshot.recentTasks, snapshot.devices) }
                snapshot.error?.let { error ->
                    item {
                        Text(
                            error,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                state.lastRefresh?.let {
                    item {
                        Text(
                            "Last updated: $it",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            if (state.showBlockingLoader) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
        }
    }
}
```

`DashboardNavigation.kt`:

```kotlin
package com.hydra.android.feature.dashboard

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val DASHBOARD_ROUTE = "dashboard"

fun NavGraphBuilder.dashboardScreen() {
    composable(DASHBOARD_ROUTE) { DashboardScreen() }
}
```

- [ ] **Step 3: Verify it compiles**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:dashboard:assembleDebug
```

Expected: `BUILD SUCCESSFUL`. If `PullToRefreshBox` is unavailable in the pinned Material3 version, use `Modifier.pullToRefresh` with a `PullToRefreshState`; do not hand-roll a refresh gesture.

- [ ] **Step 4: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/feature/dashboard
git commit -m "feat(android): 대시보드 UI — 배너/요약/디바이스/GPU/Orchs/Tasks 섹션"
```

---

### Task 12: `:feature:chat` — ViewModel

**Files:**
- Modify: `android/feature/chat/build.gradle.kts`
- Create: `.../feature/chat/ChatViewModel.kt`
- Test: `android/feature/chat/src/test/kotlin/com/hydra/android/feature/chat/ChatViewModelTest.kt`

**Interfaces:**
- Consumes: `ChatRepository` (Task 7), `SettingsSource` (Task 9's extraction), chat models (Task 2).
- Produces: `data class ChatUiState(val turns: List<ChatTurn>, val isThinking: Boolean, val pendingPlan: AgentPlan?, val pendingPlanMessage: String?, val error: String?)`, `class ChatViewModel` with `fun send(message: String)`, `fun runPendingPlan()`, `fun cancelPendingPlan()`.

- [ ] **Step 1: Add module dependencies**

Same block as `:feature:settings` with `android { namespace = "com.hydra.android.feature.chat" }`.

- [ ] **Step 2: Write the failing ViewModel tests**

```kotlin
package com.hydra.android.feature.chat

import app.cash.turbine.test
import com.hydra.android.core.data.ChatRepository
import com.hydra.android.core.model.*
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val PLAN = AgentPlan("check uptime", listOf(AgentAction("exec", JsonObject(emptyMap()))))

private class FakeChatRepository(
    var chatResult: Result<ChatResponse> = Result.success(ChatResponse("ask", "hello")),
    var executeResult: Result<AgentExecuteResponse> = Result.success(AgentExecuteResponse()),
) : ChatRepository(api = FakeUnusedApi) {
    var lastHistorySize = -1
    override suspend fun send(history: List<ChatTurn>, message: String, instruction: String?):
        Result<ChatResponse> { lastHistorySize = history.size; return chatResult }
    override suspend fun execute(plan: AgentPlan) = executeResult
}

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(repo: FakeChatRepository) =
        ChatViewModel(repo, MutableStateFlow("").let { instruction ->
            object : com.hydra.android.core.data.SettingsSource {
                override val serverUrl = MutableStateFlow("")
                override val aiInstruction = instruction
                override val hideMobileDevices = MutableStateFlow(false)
                override suspend fun setServerUrl(value: String) {}
                override suspend fun setAiInstruction(value: String) {}
                override suspend fun setHideMobileDevices(value: Boolean) {}
            }
        })

    @Test
    fun `an empty message is ignored`() = runTest {
        val repo = FakeChatRepository()
        val model = vm(repo)
        model.send("   ")
        advanceUntilIdle()
        assertEquals(-1, repo.lastHistorySize)
        assertTrue(model.state.value.turns.isEmpty())
    }

    @Test
    fun `sending appends the user turn then the assistant reply`() = runTest {
        val model = vm(FakeChatRepository())
        model.state.test {
            awaitItem()
            model.send("hi")
            advanceUntilIdle()
            val latest = expectMostRecentItem()
            assertEquals(2, latest.turns.size)
            assertEquals("user", latest.turns[0].role)
            assertEquals("assistant_ask", latest.turns[1].role)
            assertFalse(latest.isThinking)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a plan response sets the pending plan and an assistant_plan turn`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "will run uptime", PLAN))
        )
        val model = vm(repo)
        model.send("check uptime")
        advanceUntilIdle()

        val s = model.state.value
        assertEquals("check uptime", s.pendingPlan?.intent)
        assertEquals("will run uptime", s.pendingPlanMessage)
        assertEquals("assistant_plan", s.turns.last().role)
    }

    @Test
    fun `running a plan appends a system_result turn summarizing the outcome`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "go", PLAN)),
            executeResult = Result.success(AgentExecuteResponse(listOf(
                ActionResult("exec", "ok"), ActionResult("exec", "error", error = "nope"),
            ))),
        )
        val model = vm(repo)
        model.send("go"); advanceUntilIdle()
        model.runPendingPlan(); advanceUntilIdle()

        val last = model.state.value.turns.last()
        assertEquals("system_result", last.role)
        assertEquals("ran 2 action(s) — 1 ok, 1 failed", last.content)
        assertNull(model.state.value.pendingPlan)
    }

    @Test
    fun `an all-ok plan run summarizes as completed`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "go", PLAN)),
            executeResult = Result.success(AgentExecuteResponse(listOf(ActionResult("exec", "ok")))),
        )
        val model = vm(repo)
        model.send("go"); advanceUntilIdle()
        model.runPendingPlan(); advanceUntilIdle()
        assertEquals("✓ all 1 action(s) completed", model.state.value.turns.last().content)
    }

    @Test
    fun `cancelling clears the pending plan without touching the turns`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.success(ChatResponse("plan", "go", PLAN))
        )
        val model = vm(repo)
        model.send("go"); advanceUntilIdle()
        val before = model.state.value.turns.size
        model.cancelPendingPlan()
        assertNull(model.state.value.pendingPlan)
        assertEquals(before, model.state.value.turns.size)
    }

    @Test
    fun `a failure surfaces the error and clears thinking`() = runTest {
        val repo = FakeChatRepository(
            chatResult = Result.failure(ApiException(null, "서버에 연결할 수 없습니다"))
        )
        val model = vm(repo)
        model.send("hi"); advanceUntilIdle()
        assertEquals("서버에 연결할 수 없습니다", model.state.value.error)
        assertFalse(model.state.value.isThinking)
    }

    @Test
    fun `the user turn is kept in history even when the request fails`() = runTest {
        val repo = FakeChatRepository(chatResult = Result.failure(ApiException(500, "boom")))
        val model = vm(repo)
        model.send("hi"); advanceUntilIdle()
        assertEquals(1, model.state.value.turns.size)
        assertEquals("user", model.state.value.turns.first().role)
    }
}
```

`ChatRepository` must be `open` with `open suspend fun send`/`execute`; `FakeUnusedApi` is the same throwing `HydraApi` object used in Task 10 — declare a copy in this test file.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:chat:testDebugUnitTest
```

Expected: FAIL — unresolved reference `ChatViewModel`.

- [ ] **Step 4: Make `ChatRepository` open and write `ChatViewModel`**

Change `class ChatRepository` to `open class ChatRepository` and its two functions to `open suspend fun`.

```kotlin
package com.hydra.android.feature.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.ChatRepository
import com.hydra.android.core.data.SettingsSource
import com.hydra.android.core.model.ActionResult
import com.hydra.android.core.model.AgentPlan
import com.hydra.android.core.model.ChatTurn
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ChatUiState(
    val turns: List<ChatTurn> = emptyList(),
    val isThinking: Boolean = false,
    val pendingPlan: AgentPlan? = null,
    val pendingPlanMessage: String? = null,
    val error: String? = null,
)

@HiltViewModel
class ChatViewModel @Inject constructor(
    private val repository: ChatRepository,
    private val settings: SettingsSource,
) : ViewModel() {

    private val _state = MutableStateFlow(ChatUiState())
    val state: StateFlow<ChatUiState> = _state.asStateFlow()

    fun send(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty()) return

        _state.update {
            it.copy(
                turns = it.turns + ChatTurn(role = "user", content = trimmed),
                isThinking = true,
                error = null,
            )
        }

        viewModelScope.launch {
            // The repository caps the outbound history; the UI keeps all of it.
            val history = _state.value.turns
            val instruction = settings.aiInstruction.first()
            repository.send(history, trimmed, instruction).fold(
                onSuccess = { response ->
                    val role =
                        if (response.type == "plan") "assistant_plan" else "assistant_ask"
                    _state.update {
                        it.copy(
                            turns = it.turns + ChatTurn(
                                role = role,
                                content = response.message,
                                plan = response.plan,
                            ),
                            isThinking = false,
                            pendingPlan = response.plan.takeIf { response.type == "plan" },
                            pendingPlanMessage =
                                response.message.takeIf { response.type == "plan" },
                        )
                    }
                },
                onFailure = { e ->
                    _state.update { it.copy(isThinking = false, error = e.message) }
                },
            )
        }
    }

    fun runPendingPlan() {
        val plan = _state.value.pendingPlan ?: return
        _state.update { it.copy(isThinking = true, error = null) }
        viewModelScope.launch {
            repository.execute(plan).fold(
                onSuccess = { response ->
                    _state.update {
                        it.copy(
                            turns = it.turns + ChatTurn(
                                role = "system_result",
                                content = summarize(response.results),
                                results = response.results,
                            ),
                            isThinking = false,
                            pendingPlan = null,
                            pendingPlanMessage = null,
                        )
                    }
                },
                onFailure = { e ->
                    _state.update { it.copy(isThinking = false, error = e.message) }
                },
            )
        }
    }

    fun cancelPendingPlan() {
        _state.update { it.copy(pendingPlan = null, pendingPlanMessage = null) }
    }

    /** Matches iOS ChatViewModel.summary(of:) wording exactly. */
    private fun summarize(results: List<ActionResult>): String {
        val ok = results.count { it.isOk }
        val fail = results.size - ok
        return if (fail == 0) "✓ all $ok action(s) completed"
        else "ran ${results.size} action(s) — $ok ok, $fail failed"
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest :feature:chat:testDebugUnitTest
```

Expected: PASS, 8 chat tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data android/feature/chat
git commit -m "feat(android): Chat ViewModel — plan 승인 흐름 + 결과 요약"
```

---

### Task 13: `:feature:chat` — Compose UI

**Files:**
- Create: `.../feature/chat/ChatScreen.kt`, `ChatTurnRow.kt`, `PlanCard.kt`, `ChatNavigation.kt`

**Interfaces:**
- Consumes: `ChatUiState`, `ChatViewModel` (Task 12); `HydraCard` (Task 8).
- Produces: `fun NavGraphBuilder.chatScreen()` and `const val CHAT_ROUTE = "chat"`.

- [ ] **Step 1: Write `ChatTurnRow` and `PlanCard`**

`ChatTurnRow(turn: ChatTurn)` — a label line in `labelSmall` over the content in `bodyMedium`, full width, left-aligned. The label maps `user`→`YOU`, `assistant_ask`→`ASK`, `assistant_plan`→`PLAN`, `system_result`→`RESULT`, anything else→`turn.role.uppercase()`.

`PlanCard(plan: AgentPlan, message: String?, isThinking: Boolean, onRun: () -> Unit, onCancel: () -> Unit)` — a `HydraCard` with `plan.intent` in `titleSmall`, the optional `message` in `bodySmall`, a `HorizontalDivider`, one row per action showing `action.type` in a monospace `Surface` chip beside `action.argsSummary` (max 2 lines, ellipsized), then a right-aligned `TextButton("Cancel", onCancel)` and `Button("Run", onRun, enabled = !isThinking)`.

- [ ] **Step 2: Write `ChatScreen`**

```kotlin
package com.hydra.android.feature.chat

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.item
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(viewModel: ChatViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var draft by rememberSaveable { mutableStateOf("") }
    val listState = rememberLazyListState()

    // Keep the newest content in view: the pending plan when there is one,
    // otherwise the last turn. Mirrors ChatScreen.swift's scrollToBottom.
    LaunchedEffect(state.turns.size, state.pendingPlan != null) {
        val lastIndex = listState.layoutInfo.totalItemsCount - 1
        if (lastIndex >= 0) listState.animateScrollToItem(lastIndex)
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Chat") }) },
        bottomBar = {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = { Text("Ask…") },
                    maxLines = 5,
                    modifier = Modifier.weight(1f),
                )
                FilledIconButton(
                    onClick = { viewModel.send(draft); draft = "" },
                    enabled = draft.isNotBlank() && !state.isThinking,
                ) {
                    Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "보내기")
                }
            }
        },
    ) { padding ->
        if (state.turns.isEmpty() && state.pendingPlan == null) {
            Box(
                Modifier.padding(padding).fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Ask Hydra", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Ask a question or request an action.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.padding(padding),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(state.turns, key = { it.id }) { ChatTurnRow(it) }
                state.pendingPlan?.let { plan ->
                    item(key = "pendingPlan") {
                        PlanCard(
                            plan = plan,
                            message = state.pendingPlanMessage,
                            isThinking = state.isThinking,
                            onRun = viewModel::runPendingPlan,
                            onCancel = viewModel::cancelPendingPlan,
                        )
                    }
                }
                state.error?.let { error ->
                    item(key = "error") {
                        Text(error, color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall)
                    }
                }
                if (state.isThinking) {
                    item(key = "thinking") {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Text("Thinking…", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
    }
}
```

`ChatNavigation.kt`:

```kotlin
package com.hydra.android.feature.chat

import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable

const val CHAT_ROUTE = "chat"

fun NavGraphBuilder.chatScreen() {
    composable(CHAT_ROUTE) { ChatScreen() }
}
```

- [ ] **Step 3: Verify it compiles**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:chat:assembleDebug
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/feature/chat
git commit -m "feat(android): Chat UI — 대화 목록/plan 카드/입력 바"
```

---

### Task 14: `:app` — assemble the three tabs

**Files:**
- Modify: `android/app/build.gradle.kts`, `android/app/src/main/kotlin/com/hydra/android/MainActivity.kt`
- Create: `.../android/HydraApp.kt`
- Test: `android/app/src/test/kotlin/com/hydra/android/NavigationRoutesTest.kt`

**Interfaces:**
- Consumes: `dashboardScreen()`/`DASHBOARD_ROUTE`, `chatScreen()`/`CHAT_ROUTE`, `settingsScreen()`/`SETTINGS_ROUTE`, `HydraTheme`.
- Produces: the shipped app.

- [ ] **Step 1: Add feature dependencies to `:app`**

```kotlin
dependencies {
    implementation(project(":core:designsystem"))
    implementation(project(":core:data"))
    implementation(project(":feature:dashboard"))
    implementation(project(":feature:chat"))
    implementation(project(":feature:settings"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.hilt.android)
    implementation(libs.hilt.navigation.compose)
    ksp(libs.hilt.compiler)
    testImplementation(libs.junit)
}
```

`:app` also needs `id("hydra.android.compose")`, already applied in Task 1.

- [ ] **Step 2: Write the failing route test**

```kotlin
package com.hydra.android

import com.hydra.android.feature.chat.CHAT_ROUTE
import com.hydra.android.feature.dashboard.DASHBOARD_ROUTE
import com.hydra.android.feature.settings.SETTINGS_ROUTE
import org.junit.Assert.assertEquals
import org.junit.Test

class NavigationRoutesTest {

    @Test
    fun `bottom tabs are ordered dashboard, chat, settings`() {
        assertEquals(
            listOf(DASHBOARD_ROUTE, CHAT_ROUTE, SETTINGS_ROUTE),
            HydraDestination.entries.map { it.route },
        )
    }

    @Test
    fun `tab labels match the iOS wording`() {
        assertEquals(
            listOf("대시보드", "Chat", "설정"),
            HydraDestination.entries.map { it.label },
        )
    }

    @Test
    fun `the start destination is the dashboard`() {
        assertEquals(DASHBOARD_ROUTE, HydraDestination.START_ROUTE)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :app:testDebugUnitTest
```

Expected: FAIL — unresolved reference `HydraDestination`.

- [ ] **Step 4: Write `HydraApp.kt`**

```kotlin
package com.hydra.android

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.hydra.android.feature.chat.CHAT_ROUTE
import com.hydra.android.feature.chat.chatScreen
import com.hydra.android.feature.dashboard.DASHBOARD_ROUTE
import com.hydra.android.feature.dashboard.dashboardScreen
import com.hydra.android.feature.settings.SETTINGS_ROUTE
import com.hydra.android.feature.settings.settingsScreen

/**
 * The three v1 tabs. The iOS app has six (디바이스, Orchs, Tasks are v2);
 * their routes are simply absent rather than stubbed.
 */
enum class HydraDestination(
    val route: String,
    val label: String,
    val icon: ImageVector,
) {
    DASHBOARD(DASHBOARD_ROUTE, "대시보드", Icons.Filled.Speed),
    CHAT(CHAT_ROUTE, "Chat", Icons.AutoMirrored.Filled.Chat),
    SETTINGS(SETTINGS_ROUTE, "설정", Icons.Filled.Settings);

    companion object {
        const val START_ROUTE = DASHBOARD_ROUTE
    }
}

@Composable
fun HydraApp() {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route

    Scaffold(
        bottomBar = {
            NavigationBar {
                HydraDestination.entries.forEach { destination ->
                    NavigationBarItem(
                        selected = currentRoute == destination.route,
                        onClick = {
                            navController.navigate(destination.route) {
                                // Single-top tab switching: don't stack copies of a
                                // tab, and keep each tab's own state across switches.
                                popUpTo(navController.graph.findStartDestination().id) {
                                    saveState = true
                                }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = { Icon(destination.icon, contentDescription = destination.label) },
                        label = { Text(destination.label) },
                    )
                }
            }
        }
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = HydraDestination.START_ROUTE,
            modifier = Modifier.padding(padding),
        ) {
            dashboardScreen()
            chatScreen()
            settingsScreen()
        }
    }
}
```

- [ ] **Step 5: Wire `MainActivity`**

Replace the placeholder body:

```kotlin
package com.hydra.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.hydra.android.core.designsystem.HydraTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            HydraTheme { HydraApp() }
        }
    }
}
```

- [ ] **Step 6: Run the full test suite and build the APK**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew testDebugUnitTest assembleDebug
```

Expected: `BUILD SUCCESSFUL`, all module test tasks green, and `app/build/outputs/apk/debug/app-debug.apk` present.

- [ ] **Step 7: Verify against a real server**

Start the backend and install on a connected device or emulator:

```bash
cd /Users/dave/iWorks/hydra && make build-server && ./build/hydra-server &
cd android && JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :app:installDebug
```

Confirm by hand, and report what you actually saw:
1. 설정 tab: enter the server URL, then reopen the app — the URL persists and the API key field repopulates.
2. 대시보드 tab: the banner turns green with a version, the summary grid shows real counts, and values update roughly every 5 seconds without the screen flashing.
3. Pull to refresh: the spinner appears and the "Last updated" line advances.
4. Chat tab: send a question, get a reply; ask for something actionable and confirm the plan card renders with Run/Cancel, that Run appends a RESULT turn, and that Cancel clears the card.
5. Point the server URL at a dead address: the banner goes red and the dashboard shows a connection error rather than crashing.

If no device or emulator is available, say so explicitly rather than reporting this step as done.

- [ ] **Step 8: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android
git commit -m "feat(android): 하단 탭 3개 배선 — 대시보드/Chat/설정"
```

---

## Self-Review

**Spec coverage.** Module graph → Task 1. Models and the RFC3339/`@Transient` rules → Task 2. Interceptors, cleartext config, error mapping → Tasks 1 and 3. Endpoint table and Hilt network module → Task 4. Settings, `SecureStore`, `ServerConfigProvider` → Task 5. Dashboard core/auxiliary asymmetry, force-refresh semantics → Task 6. Chat history cap and instruction attachment → Task 7. Design system → Task 8. The three screens → Tasks 9, 11, 13; their ViewModels → Tasks 9, 10, 12. Navigation and bottom bar → Task 14. Build integration (`.gitignore`, Makefile) → Task 1, Step 9. Every testing-strategy row maps to a task's test step except the Compose smoke tests, which the spec itself marks "not a priority surface" — Task 11 and Task 13 verify by compilation, and Task 14 Step 7 covers the screens by manual run.

**Two interface changes discovered while writing tests, applied where they belong:** `SettingsRepository` gains a `SettingsSource` interface (Task 9, Step 4) so ViewModels can be tested without DataStore, and `DashboardRepository`/`ChatRepository` become `open` (Tasks 10 and 12) so tests can subclass them. Both are recorded in the task that first needs them.

**Type consistency.** `DashboardSnapshot` is produced in Task 6 and consumed unchanged in Tasks 10 and 11. `ChatUiState.pendingPlanMessage` is named identically in Tasks 12 and 13. `HydraApi`'s six dashboard members are re-implemented in the fakes of Tasks 6, 7, 10, and 12 — all eight members must be overridden in each fake or compilation fails, which is why each fake is spelled out in full.
