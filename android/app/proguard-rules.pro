# FujiStudio Mobile — R8 / ProGuard Rules (Day-0 Zero-Rework Baseline)

# Keep Flutter engine & plugin embedding classes invoked via JNI.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }

# Flutter embedding includes optional Play Core deferred-component hooks that are
# unused unless Android Play Feature Delivery is enabled.
-dontwarn com.google.android.play.core.**

# Keep native method signatures and JNI entry points intact under R8 minification.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# Keep FujiStudio Android application classes and future JNI/PlatformChannel bridges.
-keep class org.fujistudio.mobile.** { *; }

# Note: Native shared libraries (libfujistudio_core.so) are loaded by Dart FFI
# (`DynamicLibrary.open("libfujistudio_core.so")`) and packaged by AGP jniLibs.
# R8 only shrinks DEX bytecode; symbol visibility in libfujistudio_core.so is
# controlled by FS_API (__attribute__((visibility("default")))) in CMake/C++.
