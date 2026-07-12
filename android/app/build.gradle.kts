import java.io.File
import java.io.FileInputStream
import java.util.*

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is configured via key.properties. When the file is absent
// (e.g. forks/CI without the keystore secrets), fall back to debug signing so
// the build still succeeds.
val keyPropertiesFile = File("key.properties")
val hasReleaseKeystore = keyPropertiesFile.exists()

val keyProperties = Properties().apply {
    if (hasReleaseKeystore) {
        load(FileInputStream(keyPropertiesFile))
    }
}

// Get all properties from key.properties file
val detKeyAlias = keyProperties.getProperty("keyAlias")
val detKeyPassword = keyProperties.getProperty("keyPassword")
val detStoreFile = keyProperties.getProperty("storeFile")
val detStorePassword = keyProperties.getProperty("storePassword")

// Validate that required properties exist
if (hasReleaseKeystore) {
    require(detKeyAlias != null) { "keyAlias not found in key.properties file." }
    require(detKeyPassword != null) { "keyPassword not found in key.properties file." }
    require(detStoreFile != null) { "storeFile not found in key.properties file." }
    require(detStorePassword != null) { "storePassword not found in key.properties file." }
}

android {
    namespace = "de.doen1el.calibreWebCompanion"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        applicationId = "de.doen1el.calibreWebCompanion"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode * 10 + 3
        versionName = flutter.versionName
    }

    dependenciesInfo {
        // Disables dependency metadata when building APKs.
        includeInApk = false
        // Disables dependency metadata when building Android App Bundles.
        includeInBundle = false
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = detKeyAlias
                keyPassword = detKeyPassword
                storeFile = file(detStoreFile)
                storePassword = detStorePassword
            }
        }
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = true
            isShrinkResources = true

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            isDebuggable = true
        }

        getByName("release") {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            isMinifyEnabled = true
            isShrinkResources = true
            
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

flutter {
    source = "../.."
}