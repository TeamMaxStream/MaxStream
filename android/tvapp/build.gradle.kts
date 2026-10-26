import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Compose compiler plugin tracks the Kotlin version exactly.
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.20"
}

// Keep Kotlin's bytecode target in sync with compileOptions (Java 21), which
// is otherwise left at the Kotlin/AGP default (17) and fails the build with
// "Inconsistent JVM Target Compatibility".
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

// Apply Google Services plugin only for standard builds (has GOOGLE_SERVICES_JSON).
// FOSS builds set -PstandardFirebase=false (or omit it) — Kotlin stubs handle compilation.
val enableFirebase = project.findProperty("standardFirebase")?.toString()?.toBoolean() == true
if (enableFirebase) {
    apply(plugin = "com.google.gms.google-services")
}

val keystoreProps = Properties()
val keystoreFile = rootProject.file("keystore.properties")
if (keystoreFile.exists()) {
    keystoreProps.load(FileInputStream(keystoreFile))
}

@Suppress("Deprecation")
android {
    namespace = "com.maxstream.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.maxstream.tv"
        minSdk = 23
        targetSdk = 34
        versionCode = 10
        versionName = "1.8.0"
        vectorDrawables.useSupportLibrary = true
    }

    signingConfigs {
        create("release") {
            val storeFilePath = keystoreProps.getProperty("storeFile")
            if (storeFilePath != null) {
                storeFile = file(storeFilePath)
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName("release").takeIf { it.storeFile != null }
        }
        debug {
            applicationIdSuffix = ".debug"
            isDebuggable = true
        }
    }

    flavorDimensions += listOf("edition", "install")

    productFlavors {
        create("foss") {
            dimension = "edition"
            applicationIdSuffix = ".foss"
        }
        create("standard") {
            dimension = "edition"
            applicationIdSuffix = ".standard"
        }
        create("universal") { dimension = "install" }
        create("arm") {
            dimension = "install"
            ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
        isCoreLibraryDesugaringEnabled = true
    }

    buildFeatures {
        compose = true
        viewBinding = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "2.3.20"
    }

    packaging {
        resources {
            excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
        }
    }
}

repositories {
    google()
    mavenCentral()
    maven("https://jitpack.io")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.4")
    implementation("androidx.activity:activity-ktx:1.9.2")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.fragment:fragment-ktx:1.8.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")

    val composeBom = platform("androidx.compose:compose-bom:2026.04.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    // LiveData <-> Compose bridging: screens observe ViewModels with
    // observeAsState() (Home/Details/Series). Version pinned explicitly so the
    // artifact never depends on BOM constraint resolution.
    implementation("androidx.compose.runtime:runtime-livedata:1.7.6")
    implementation("androidx.navigation:navigation-compose:2.8.0")
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.10.1")
    implementation("androidx.media3:media3-ui:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")
    implementation("androidx.media3:media3-session:1.10.1")
    implementation("androidx.media3:media3-datasource-okhttp:1.10.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    implementation("com.github.bumptech.glide:glide:4.16.0")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("io.coil-kt:coil-compose:2.6.0")

    // Firebase — only included for standard builds (has GOOGLE_SERVICES_JSON + service account).
    // FOSS builds skip these; MaxStreamTvApp.initFirebase() is a no-op.
    if (enableFirebase) {
        implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
        implementation("com.google.firebase:firebase-auth-ktx")
        implementation("com.google.firebase:firebase-database-ktx")
    } else {
        // FOSS stubs need play-services-tasks for the Task<> API surface
        implementation("com.google.android.gms:play-services-tasks:18.3.0")
    }
}
