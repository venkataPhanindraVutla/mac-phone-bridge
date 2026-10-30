# Third-party licences

Android Mirroring is licensed under the Apache License, Version 2.0 (`LICENSE`). This file lists every
third-party component the apps ship or build from, with its licence. Attribution lines are in `NOTICE`.

How this list was made (milestone 0.5, 2026-10-30):

- **Android:** `./gradlew :core:adb:dependencies --configuration releaseRuntimeClasspath` and
  `./gradlew :app:dependencies --configuration ossReleaseRuntimeClasspath`, licences from each artifact's POM.
  `:helper` has no runtime dependencies.
- **Mac:** `mac/Packages/AMKit/Package.resolved`.
- Rule: anything that is not Apache-2.0, MIT, BSD or ISC compatible goes to the project's controller before it ships.
  The only such component is `spake2-android` (LGPL-3.0), shipped as described below.

## Components

| Component | Version | Where it is used | Licence | Source |
|---|---|---|---|---|
| scrcpy-server (vendored source, two patches) | 5.0.1 (built as 5.0.1-am1) | Android: `:helper`, shipped as `assets/anmirror-helper.jar` (Full mode) | Apache-2.0 | https://github.com/Genymobile/scrcpy (tag v5.0.1, see `android/helper/UPSTREAM.md`) |
| libadb-android | 3.1.1 | Android: `:core:adb` (Full mode ADB client) | GPL-3.0-or-later OR Apache-2.0; **used under Apache-2.0** | https://github.com/MuntashirAkon/libadb-android (JitPack) |
| spake2-android (transitive, via libadb-android) | 2.2.1 | Android: `:core:adb` (ADB pairing); prebuilt `libspake2.so` for arm64-v8a, armeabi-v7a, x86, x86_64 | **LGPL-3.0**, used unmodified as a separate library (see below) | https://github.com/MuntashirAkon/spake2-java |
| conscrypt-android | 2.5.3 | Android: `:core:adb` (TLS for ADB); prebuilt `libconscrypt_jni.so` (four ABIs) with BoringSSL | Apache-2.0; bundled BoringSSL: OpenSSL / SSLeay and ISC licences | https://github.com/google/conscrypt, https://boringssl.googlesource.com/boringssl |
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
| swift-crypto | 5.0.3 | Mac: AMKit | Apache-2.0; vendored BoringSSL: OpenSSL / SSLeay and ISC licences | https://github.com/apple/swift-crypto |
| swift-certificates | 1.21.1 | Mac: AMKit | Apache-2.0 | https://github.com/apple/swift-certificates |
| swift-asn1 | 1.7.3 | Mac: AMKit (via swift-certificates) | Apache-2.0 | https://github.com/apple/swift-asn1 |
| Gson (tests only, not shipped) | 2.13.2 | Android: `:helper` unit tests | Apache-2.0 | https://github.com/google/gson |
| JUnit (tests only, not shipped) | 4.13.2 | Android: unit tests | EPL-1.0 | https://github.com/junit-team/junit4 |

The Mac app's scrcpy stream and control code (`FeatureMirror`) is a new implementation of the scrcpy protocol,
not a copy of scrcpy code.

## spake2-android (LGPL-3.0)

`libadb-android` depends on `spake2-android` 2.2.1 for Wireless debugging pairing (SPAKE2). It is licensed under the
GNU Lesser General Public License, version 3.0, and ships prebuilt `libspake2.so` libraries plus a small Java
wrapper. Android Mirroring uses it **unmodified, as a separate library**: it stays its own AAR dependency, its
native code stays its own shared library, and nothing of ours is linked into it. Anyone may replace it with
another build of `spake2-android` (from the source below) by changing the dependency and rebuilding the app.
The rest of Android Mirroring stays under the Apache License, Version 2.0.

- Source: https://github.com/MuntashirAkon/spake2-java (version 2.2.1)
- The LGPL-3.0 adds permissions to the GNU General Public License, version 3: https://www.gnu.org/licenses/gpl-3.0.txt

The LGPL-3.0 text, verbatim:

```text
		   GNU LESSER GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

 Copyright (C) 2007 Free Software Foundation, Inc. <http://fsf.org/>
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.


  This version of the GNU Lesser General Public License incorporates
the terms and conditions of version 3 of the GNU General Public
License, supplemented by the additional permissions listed below.

  0. Additional Definitions. 

  As used herein, "this License" refers to version 3 of the GNU Lesser
General Public License, and the "GNU GPL" refers to version 3 of the GNU
General Public License.

  "The Library" refers to a covered work governed by this License,
other than an Application or a Combined Work as defined below.

  An "Application" is any work that makes use of an interface provided
by the Library, but which is not otherwise based on the Library.
Defining a subclass of a class defined by the Library is deemed a mode
of using an interface provided by the Library.

  A "Combined Work" is a work produced by combining or linking an
Application with the Library.  The particular version of the Library
with which the Combined Work was made is also called the "Linked
Version".

  The "Minimal Corresponding Source" for a Combined Work means the
Corresponding Source for the Combined Work, excluding any source code
for portions of the Combined Work that, considered in isolation, are
based on the Application, and not on the Linked Version.

  The "Corresponding Application Code" for a Combined Work means the
object code and/or source code for the Application, including any data
and utility programs needed for reproducing the Combined Work from the
Application, but excluding the System Libraries of the Combined Work.

  1. Exception to Section 3 of the GNU GPL.

  You may convey a covered work under sections 3 and 4 of this License
without being bound by section 3 of the GNU GPL.

  2. Conveying Modified Versions.

  If you modify a copy of the Library, and, in your modifications, a
facility refers to a function or data to be supplied by an Application
that uses the facility (other than as an argument passed when the
facility is invoked), then you may convey a copy of the modified
version:

   a) under this License, provided that you make a good faith effort to
   ensure that, in the event an Application does not supply the
   function or data, the facility still operates, and performs
   whatever part of its purpose remains meaningful, or

   b) under the GNU GPL, with none of the additional permissions of
   this License applicable to that copy.

  3. Object Code Incorporating Material from Library Header Files.

  The object code form of an Application may incorporate material from
a header file that is part of the Library.  You may convey such object
code under terms of your choice, provided that, if the incorporated
material is not limited to numerical parameters, data structure
layouts and accessors, or small macros, inline functions and templates
(ten or fewer lines in length), you do both of the following:

   a) Give prominent notice with each copy of the object code that the
   Library is used in it and that the Library and its use are
   covered by this License.

   b) Accompany the object code with a copy of the GNU GPL and this license
   document.

  4. Combined Works.

  You may convey a Combined Work under terms of your choice that,
taken together, effectively do not restrict modification of the
portions of the Library contained in the Combined Work and reverse
engineering for debugging such modifications, if you also do each of
the following:

   a) Give prominent notice with each copy of the Combined Work that
   the Library is used in it and that the Library and its use are
   covered by this License.

   b) Accompany the Combined Work with a copy of the GNU GPL and this license
   document.

   c) For a Combined Work that displays copyright notices during
   execution, include the copyright notice for the Library among
   these notices, as well as a reference directing the user to the
   copies of the GNU GPL and this license document.

   d) Do one of the following:

       0) Convey the Minimal Corresponding Source under the terms of this
       License, and the Corresponding Application Code in a form
       suitable for, and under terms that permit, the user to
       recombine or relink the Application with a modified version of
       the Linked Version to produce a modified Combined Work, in the
       manner specified by section 6 of the GNU GPL for conveying
       Corresponding Source.

       1) Use a suitable shared library mechanism for linking with the
       Library.  A suitable mechanism is one that (a) uses at run time
       a copy of the Library already present on the user's computer
       system, and (b) will operate properly with a modified version
       of the Library that is interface-compatible with the Linked
       Version. 

   e) Provide Installation Information, but only if you would otherwise
   be required to provide such information under section 6 of the
   GNU GPL, and only to the extent that such information is
   necessary to install and execute a modified version of the
   Combined Work produced by recombining or relinking the
   Application with a modified version of the Linked Version. (If
   you use option 4d0, the Installation Information must accompany
   the Minimal Corresponding Source and Corresponding Application
   Code. If you use option 4d1, you must provide the Installation
   Information in the manner specified by section 6 of the GNU GPL
   for conveying Corresponding Source.)

  5. Combined Libraries.

  You may place library facilities that are a work based on the
Library side by side in a single library together with other library
facilities that are not Applications and are not covered by this
License, and convey such a combined library under terms of your
choice, if you do both of the following:

   a) Accompany the combined library with a copy of the same work based
   on the Library, uncombined with any other library facilities,
   conveyed under the terms of this License.

   b) Give prominent notice with the combined library that part of it
   is a work based on the Library, and explaining where to find the
   accompanying uncombined form of the same work.

  6. Revised Versions of the GNU Lesser General Public License.

  The Free Software Foundation may publish revised and/or new versions
of the GNU Lesser General Public License from time to time. Such new
versions will be similar in spirit to the present version, but may
differ in detail to address new problems or concerns.

  Each version is given a distinguishing version number. If the
Library as you received it specifies that a certain numbered version
of the GNU Lesser General Public License "or any later version"
applies to it, you have the option of following the terms and
conditions either of that published version or of any later version
published by the Free Software Foundation. If the Library as you
received it does not specify a version number of the GNU Lesser
General Public License, you may choose any version of the GNU Lesser
General Public License ever published by the Free Software Foundation.

  If the Library as you received it specifies that a proxy can decide
whether future versions of the GNU Lesser General Public License shall
apply, that proxy's public statement of acceptance of any version is
permanent authorization for you to choose that version for the
Library.
```

## Follow-ups

- **F-Droid and JitPack.** `libadb-android` (and with it `spake2-android`) is published on JitPack only, which the
  build reaches through a repository restricted to `com.github.MuntashirAkon*`. F-Droid builds need it from source:
  an srclib, or a vendored source copy.
- **Prebuilt native libraries.** `spake2-android` (`libspake2.so`) and `conscrypt-android` (`libconscrypt_jni.so`)
  ship prebuilt `.so` files for four ABIs. F-Droid would need them built from source too (or a Kotlin SPAKE2
  behind `AdbClient`, the plan's fallback).
- The helper itself is no binary of ours: Gradle builds it from the vendored source in `android/helper`.
