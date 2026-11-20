import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "org.fujistudio.mobile"
    compileSdk = flutter.compileSdkVersion

    // Locked to the exact NDK version installed and verified on the build host.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        resValues = true
    }

    defaultConfig {
        applicationId = "org.fujistudio.mobile"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++20")
                arguments += listOf("-DANDROID_STL=c++_static")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "FujiStudio Dev")
            // Dev flavor ships arm64-v8a (physical devices) + x86_64 (emulators).
            ndk {
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            resValue("string", "app_name", "FujiStudio Staging")
            // Staging release strictly targets arm64-v8a to avoid x86/32-bit bloat.
            ndk {
                abiFilters += listOf("arm64-v8a")
            }
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                val storeFileProp = keystoreProperties.getProperty("storeFile")
                if (!storeFileProp.isNullOrBlank()) {
                    storeFile = rootProject.file(storeFileProp)
                }
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }

    packaging {
        jniLibs {
            // Preserve uncompressed native libraries aligned for Android 15+ 16 KB page sizes.
            useLegacyPackaging = false
        }
    }
}

androidComponents {
    // Hard-enforce arm64-v8a-only jniLibs on staging even if Flutter CLI is invoked
    // without `--target-platform android-arm64`.
    onVariants(selector().withFlavor("environment" to "staging")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf("**/armeabi-v7a/**", "**/x86_64/**", "**/x86/**"),
        )
    }
}

gradle.taskGraph.whenReady {
    val isReleaseBuild = allTasks.any { it.name.contains("Release", ignoreCase = true) }
    if (isReleaseBuild && !keystorePropertiesFile.exists()) {
        throw GradleException(
            "Missing android/key.properties for release signing. " +
                "Copy android/key.properties.example or run scripts/gen_staging_keystore.ps1.",
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
