# Third-party licences

Android Mirroring is licensed under the Apache License, Version 2.0 (`LICENSE`). This file lists every
third-party component the apps ship or build from, with its licence. Attribution lines are in `NOTICE`.

**Licence texts.** The full texts, each headed by the components that use it and their copyright lines, ship
inside the Android app as `assets/licenses/` (source: `android/app/src/main/assets/licenses/`): `NOTICE`,
`Apache-2.0.txt`, `BSD-3-Clause.txt`, `MIT.txt`, `ISC.txt`, `LGPL-2.1.txt`, `LGPL-3.0.txt`, `GPL-3.0.txt` and
`BoringSSL.txt` (ruling R41). The same files are attached to each GitHub release. `LicenseAssetsTest` (app unit
tests) checks that they are there, that the bundled NOTICE is this repository's NOTICE, and that NOTICE names
every module on the release runtime classpath.

How this list was made (milestone 0.5, 2026-10-30):

- **Android:** `./gradlew :core:adb:dependencies --configuration releaseRuntimeClasspath` and
  `./gradlew :app:dependencies --configuration ossReleaseRuntimeClasspath`, licences from each artifact's POM.
  `:helper` has no runtime dependencies.
- **Mac:** `mac/Packages/AMKit/Package.resolved`.
- libadb-android's and spake2-android's own sources (tag 3.1.1 and 2.2.1, with the `spake2-c` submodule) were read
  for their `SPDX-License-Identifier` lines and file headers; POMs alone miss the per-file licences.
- Copyright holders without years (AndroidX, Kotlin, ZXing, Guava, JSpecify) are as their projects' headers name them.
- Rule: anything that is not Apache-2.0, MIT, BSD or ISC compatible goes to the project's controller before it ships.
  The only such component is `spake2-android` (LGPL-3.0, with an LGPL-2.1-or-later file in its native code),
  shipped as described below.

## Components

| Component | Version | Where it is used | Licence | Source |
|---|---|---|---|---|
| scrcpy-server (vendored source, two patches) | 5.0.1 (built as 5.0.1-am1) | Android: `:helper`, shipped as `assets/anmirror-helper.jar` (Full mode) | Apache-2.0 | https://github.com/Genymobile/scrcpy (tag v5.0.1, see `android/helper/UPSTREAM.md`) |
| libadb-android | 3.1.1 | Android: `:core:adb` (Full mode ADB client) | GPL-3.0-or-later OR Apache-2.0 (**used under Apache-2.0**), with parts under BSD-3-Clause (`AdbConnection`, `AdbProtocol`, `AdbStream`: Copyright 2013 Cameron Gutman; `AdbAuthenticationFailedException`: Copyright 2020 Sam Palmer) and MIT (`PRNGFixes`: Copyright 2013 Google Inc.) | https://github.com/MuntashirAkon/libadb-android (JitPack; tag 3.1.1, `COPYING` and `LICENSES/`) |
| spake2-android (transitive, via libadb-android) | 2.2.1 | Android: `:core:adb` (ADB pairing); prebuilt `libspake2.so` for arm64-v8a, armeabi-v7a, x86, x86_64 | **LGPL-3.0**, used unmodified as a separate library (see below). `libspake2.so` also contains ISC (`spake2.c`, `ed25519.h`: Copyright 2020 Google Inc., 2021 Muntashir Al-Islam), MIT (`curve25519_32.h`: Copyright 2015-2020 the fiat-crypto authors), Apache-2.0 (`spake2.h`) and LGPL-2.1-or-later (`sha512.c`, from glibc: Copyright 2007-2015 Free Software Foundation, Inc.) parts | https://github.com/MuntashirAkon/spake2-java (tag 2.2.1), native code https://github.com/MuntashirAkon/spake2-c |
| conscrypt-android | 2.5.3 | Android: `:core:adb` (TLS for ADB); prebuilt `libconscrypt_jni.so` (four ABIs) with BoringSSL | Apache-2.0; bundled BoringSSL: OpenSSL License, original SSLeay License, ISC and MIT (`BoringSSL.txt`, BoringSSL's LICENSE at tag 0.20240913.0, from Conscrypt 2.5.3's period; the exact BoringSSL revision inside 2.5.3 is not published in the AAR) | https://github.com/google/conscrypt, https://boringssl.googlesource.com/boringssl |
| Bouncy Castle `bcpkix-jdk18on`, `bcutil-jdk18on`, `bcprov-jdk18on` | 1.86 | Android: `:core:adb` (ADB key and certificate) | Bouncy Castle Licence (MIT) | https://www.bouncycastle.org/licence.html |
| AndroidX (activity, annotation, annotation-experimental, arch core, autofill, collection, concurrent-futures, core, core-ktx, core-viewtree, customview-poolingcontainer, emoji2, graphics-path, interpolator, lifecycle, navigationevent, profileinstaller, savedstate, startup, tracing, versionedparcelable, window) | per `:app:dependencies` (core 1.18.0, activity 1.12.4, lifecycle 2.10.0, annotation 1.9.1) | Android: app; `androidx.annotation` also via libadb-android and spake2-android | Apache-2.0 | https://developer.android.com/jetpack/androidx |
| Jetpack Compose (runtime, ui, foundation, animation, material3, material-ripple) | BOM 2026.09.00 (1.12.1) | Android: app UI | Apache-2.0 | https://developer.android.com/jetpack/compose |
| Kotlin standard library | 2.4.21 | Android: all Kotlin modules, `:core:adb` | Apache-2.0 | https://github.com/JetBrains/kotlin |
| JetBrains annotations | 23.0.0 | Android: transitive (Kotlin) | Apache-2.0 | https://github.com/JetBrains/java-annotations |
| kotlinx.coroutines | 1.11.0 | Android | Apache-2.0 | https://github.com/Kotlin/kotlinx.coroutines |
| kotlinx.serialization | 1.11.0 | Android | Apache-2.0 | https://github.com/Kotlin/kotlinx.serialization |
| Protocol Buffers (protobuf-javalite, protobuf-kotlin-lite) | 4.36.2 | Android: `:core:protocol` | BSD-3-Clause | https://github.com/protocolbuffers/protobuf |
| ZXing Android Embedded | 4.3.0 | Android: app (QR scanning) | Apache-2.0 | https://github.com/journeyapps/zxing-android-embedded |
| ZXing core | 3.4.1 | Android: transitive (ZXing Android Embedded) | Apache-2.0 | https://github.com/zxing/zxing |
| Guava `listenablefuture` | 1.0 | Android: transitive (AndroidX) | Apache-2.0 | https://github.com/google/guava |
| JSpecify | 1.0.0 | Android: transitive (AndroidX) | Apache-2.0 | https://github.com/jspecify/jspecify |
| swift-protobuf | 1.39.0 | Mac: AMKit | Apache-2.0 | https://github.com/apple/swift-protobuf |
| swift-crypto | 5.0.3 | Mac: AMKit | Apache-2.0; its vendored BoringSSL files are under Apache-2.0 too (BoringSSL was relicensed) | https://github.com/apple/swift-crypto |
| swift-certificates | 1.21.1 | Mac: AMKit | Apache-2.0 | https://github.com/apple/swift-certificates |
| swift-asn1 | 1.7.3 | Mac: AMKit (via swift-certificates) | Apache-2.0 | https://github.com/apple/swift-asn1 |
| Gson (tests only, not shipped) | 2.13.2 | Android: `:helper` unit tests | Apache-2.0 | https://github.com/google/gson |
| JUnit (tests only, not shipped) | 4.13.2 | Android: unit tests | EPL-1.0 | https://github.com/junit-team/junit4 |

The Mac app's scrcpy stream and control code (`FeatureMirror`) is a new implementation of the scrcpy protocol,
not a copy of scrcpy code.

## spake2-android (LGPL-3.0)

`libadb-android` depends on `spake2-android` 2.2.1 for Wireless debugging pairing (SPAKE2). It is licensed under the
GNU Lesser General Public License, version 3.0, and ships prebuilt `libspake2.so` libraries plus a small Java
wrapper (`Spake2Context`, `Spake2Role`). Android Mirroring uses it **unmodified, as a separate library**: it stays its
own AAR dependency, its native code stays its own shared library, and nothing of ours is linked into it. Anyone may
replace it with another build of `spake2-android` (from the source below) by changing the dependency and rebuilding
the app. The rest of Android Mirroring stays under the Apache License, Version 2.0.

- Source: https://github.com/MuntashirAkon/spake2-java (tag 2.2.1); the native code is the `spake2-c` submodule,
  https://github.com/MuntashirAkon/spake2-c.
- `libspake2.so` is built from `spake2-c/spake2.c` (ISC, from BoringSSL), `ed25519.h` (ISC) with
  `curve25519_32.h` (MIT, fiat-crypto), `sha512.c` (LGPL-2.1-or-later, from the GNU C Library) and `spake2_jni.cpp`
  (the repository's LGPL-3.0). Each text is in `assets/licenses/`.
- LGPL-3.0 §4(b) asks for the GNU GPL v3 text as well as the LGPL's: both are bundled (`GPL-3.0.txt`, `LGPL-3.0.txt`;
  the LGPL-3.0 text is spake2-java's own `LICENSE`).

## Follow-ups

- **F-Droid and JitPack.** `libadb-android` (and with it `spake2-android`) is published on JitPack only, which the
  build reaches through a repository restricted to `com.github.MuntashirAkon*`. F-Droid builds need it from source:
  an srclib, or a vendored source copy.
- **Prebuilt native libraries.** `spake2-android` (`libspake2.so`) and `conscrypt-android` (`libconscrypt_jni.so`)
  ship prebuilt `.so` files for four ABIs. F-Droid would need them built from source too (or a Kotlin SPAKE2
  behind `AdbClient`, the plan's fallback).
- The helper itself is no binary of ours: Gradle builds it from the vendored source in `android/helper`.
- **Reproducible helper builds.** `BuildConfig.HELPER_SHA256` depends on the toolchain (AGP, D8, compileSdk). The app
  only compares against its own build's value, so this is about reproducible builds (F-Droid): pin AGP/D8/compileSdk
  for `:helper` and check that two clean builds give the same jar.
- **In-app licences screen** (0.9): show `assets/licenses/` in the app. Until then the texts ship as assets and with
  each GitHub release.
- **GitHub releases:** attach `android/app/src/main/assets/licenses/*` to each release (release checklist).
- **`core/transfer` test vectors** are passed as a system-property path, not a declared input, so editing the
  file-name vectors doesn't re-run its tests (the review's note on Task 2; `:helper` is fixed).
