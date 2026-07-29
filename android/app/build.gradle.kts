import java.io.FileInputStream
import java.util.*

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
// ---------------------------------------------------------------------------
// Signing is configured through `android/key.properties`. Resolve it against
// the root project instead of `File("key.properties")`: a bare relative File is
// resolved against the JVM working directory, which Gradle documents as
// unreliable because a reused daemon can carry a stale working directory.
val keyPropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keyPropertiesFile.exists()

// Escape hatch for forks that knowingly want an installable "release" build
// without the real keystore. It has to be requested explicitly, e.g.
//     ./gradlew assembleRelease -PallowDebugSigning=true
//     ORG_GRADLE_PROJECT_allowDebugSigning=true flutter build apk --release
// A debug-signed build must never be published: it is signed with the shared,
// throwaway Android debug key, so it cannot be updated by a real release and
// offers no authenticity guarantee whatsoever.
val allowDebugSigning = project.findProperty("allowDebugSigning")?.toString()?.let { raw ->
    raw.isBlank() || raw.equals("true", ignoreCase = true) || raw == "1"
} ?: false

// Only guard invocations that actually produce release artifacts, so debug
// workflows (`flutter run`, `flutter build apk --debug`) keep working on
// machines that have no keystore.
val releaseBuildRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("Release", ignoreCase = true)
}

if (!hasReleaseKeystore && releaseBuildRequested && !allowDebugSigning) {
    throw GradleException(
        """

        Refusing to build a release artifact: release signing is not configured.

        Expected: ${keyPropertiesFile.absolutePath}
        containing storeFile, storePassword, keyAlias and keyPassword.

        Fix this in one of two ways:

          1. Configure real signing - create android/key.properties (and the
             keystore it points at). This is what CI does from the
             KEYSTORE_BASE64 / KEYSTORE_PASSWORD / KEY_PASSWORD / KEY_ALIAS
             secrets.

          2. Explicitly opt in to a throwaway debug-signed build, for local
             testing only, by setting the allowDebugSigning project property:

                 ./gradlew assembleRelease -PallowDebugSigning=true
                 ORG_GRADLE_PROJECT_allowDebugSigning=true flutter build apk --release
                 (or add allowDebugSigning=true to android/gradle.properties)

        The build used to fall back to debug signing silently, which produced a
        "release" APK signed with the public Android debug key and shipped it to
        CI artifacts and GitHub release drafts. That fallback is now opt-in.
        """.trimIndent()
    )
}

if (!hasReleaseKeystore && allowDebugSigning) {
    logger.warn("")
    logger.warn("**************************************************************")
    logger.warn("* WARNING: -PallowDebugSigning=true and no key.properties.    *")
    logger.warn("* Release builds will be signed with the ANDROID DEBUG KEY.   *")
    logger.warn("* The resulting artifact is for local testing ONLY - do not   *")
    logger.warn("* upload, publish or attach it to a release.                  *")
    logger.warn("**************************************************************")
    logger.warn("")
}

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
            // With a keystore this is the normal, unchanged signed path.
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else if (allowDebugSigning) {
                // Explicitly opted in above; a loud warning was already printed.
                signingConfig = signingConfigs.getByName("debug")
            }
            // Otherwise no signing config is attached: the guard at the top of
            // this file has already failed any release task, and any release
            // path that somehow reaches here produces an obviously unsigned
            // artifact rather than a debug-signed lookalike.

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