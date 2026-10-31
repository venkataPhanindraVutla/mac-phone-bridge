# Release builds are not minified today (isMinifyEnabled = false); these rules make sure turning it
# on later can't silently break Full mode.

# libadb-android: :core:adb reaches SslUtils.sslContext by reflection (the per-identity TLS context
# cache), and reads PairingConnectionCtx frames as a log hint. Keep the library's names whole.
-keep class io.github.muntashirakon.adb.** { *; }
