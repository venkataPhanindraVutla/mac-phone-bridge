# Release builds are minified (R8). Keep here whatever is reached by reflection or by name.

# libadb-android: :core:adb reaches SslUtils.sslContext by reflection (the per-identity TLS context
# cache), and reads PairingConnectionCtx frames as a log hint. Keep the library's names whole.
-keep class io.github.muntashirakon.adb.** { *; }

# protobuf-javalite reads each message's fields by name (RawMessageInfo); renaming or removing them
# breaks parsing at run time, not at build time.
-keep class * extends com.google.protobuf.GeneratedMessageLite { <fields>; }

# Conscrypt's adapters for Android 4.x platform sockets name classes that only existed on those
# releases (minSdk is 29, so they are never loaded).
-dontwarn com.android.org.conscrypt.SSLParametersImpl
-dontwarn org.apache.harmony.xnet.provider.jsse.SSLParametersImpl

# Shrink, don't rename: it's open source, and testers' logs and problem reports name real classes.
-dontobfuscate
