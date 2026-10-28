# Android Mirroring

**Your Android phone, part of your Mac.** An open-source pair of native apps (Swift on macOS, Kotlin on Android) that brings Continuity-style features to Android users on a Mac.

> **Status: milestone 0.2 is code-complete and being verified on real devices.** On top of 0.1 (pairing, a secure connection, phone status in the Mac menu bar, find my phone), it adds notifications on the Mac with actions and inline reply, one-time-code copy, contacts for caller names, and calls (see, answer, decline, mute and hang up). The other features below are planned. Results so far: [0.1 results](docs/milestones/0.1-results.md), [0.2 results](docs/milestones/0.2-results.md).

### What's in 0.2

- **Notifications on your Mac,** with action buttons and inline reply, a per-app filter, and dismissals that go both ways.
- **One-time codes:** a "Copy code" button on notifications that contain a sign-in code.
- **Contacts:** synced to an encrypted file on your Mac, used only for caller names; off with one switch in Settings.
- **Calls:** a panel for incoming calls, with Answer, Decline, Mute and Hang up from the Mac. Needs call-log and answer-calls access, which the open-source build asks for.
- No SMS or MMS access: the Android app asks for no SMS permission.

## What it will do (version 1)

- 🔔 **Notifications on your Mac,** with actions and inline reply (in 0.2)
- 📁 **Files both ways:** drag, Share menu, and your phone in Finder's sidebar
- 📋 **Shared clipboard** for text
- 📞 **Calls:** see, answer and decline from your Mac (in 0.2)
- 🎵 **Music controller,** including your Mac's media keys
- 🖥️ **Screen mirroring with full control:** use WhatsApp and any app with your Mac's keyboard and mouse
- Also:
  - phone status in the menu bar
  - find my phone
  - one-time-code copy
  - Send to Mac / Send to phone
  - Do Not Disturb sync
  - instant screenshots
  - recent photos
  - caller ID
  - auto-lock your Mac when you walk away
  - phone as trackpad / presentation remote

**Version 2:** phone as webcam, phone as microphone, one-click hotspot.

**Private by design:** no account, no cloud, no telemetry. Your devices talk directly to each other, encrypted.

## Docs

- [Product requirements (PRD)](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Versions & roadmap](docs/ROADMAP.md)

## Build it

You need a Mac (Apple silicon or Intel) to build both apps.

### Prerequisites

- **Xcode 26 or later** (Swift 6).
- **xcodegen:** `brew install xcodegen`
- **protoc 4.36.2.** Download it from Maven Central and check it. This is the same pinned version CI uses. Maven publishes only SHA-1 for these files, so the Intel check uses SHA-1 (the value from the `.sha1` file next to the download). The Apple silicon SHA-256 was computed from the downloaded file. Both binaries passed `codesign --verify` when checked. The install only happens if the checksum passes:
  ```sh
  U=https://repo1.maven.org/maven2/com/google/protobuf/protoc/4.36.2
  if [ "$(uname -m)" = arm64 ]; then
    F=protoc-4.36.2-osx-aarch_64.exe; ALGO=256; HASH=765ccb18be73e565bfc3e2ad94e85039ca28f928b3e62b487e51b7b8fdf1dcfb
  else
    F=protoc-4.36.2-osx-x86_64.exe; ALGO=1; HASH=9ca6235adbf070c0931273b809de5063e566c32f
  fi
  if curl -fsSL -o protoc "$U/$F" \
     && echo "$HASH  protoc" | shasum -a "$ALGO" -c - \
     && chmod +x protoc \
     && mkdir -p "$HOME/.local/bin" \
     && mv protoc "$HOME/.local/bin/protoc"; then
    echo "protoc installed to $HOME/.local/bin (make sure it is on your PATH)"
    codesign --verify -vv "$HOME/.local/bin/protoc"   # optional: signature check
  else
    echo "protoc not installed (download, checksum or install step failed)"; rm -f protoc
  fi
  ```
- **JDK 21,** any vendor. Point `JAVA_HOME` at it.
- **Android SDK** with platform **37.1** (Android Studio's SDK Manager, or `sdkmanager "platforms;android-37.1"`). Put the SDK path in `android/local.properties` as `sdk.dir=...`, or set `ANDROID_HOME`.

### Build and test

Run these from the repository root.

```sh
scripts/gen-proto.sh                                  # regenerate Swift protobuf sources (--check to verify only)
python3 -I protocol/tools/make_vectors.py --check     # protocol test vectors are up to date
swift test --package-path mac/Packages/AMKit          # Mac library tests

xcodegen --spec mac/project.yml                       # generate the Xcode project (not committed)
xcodebuild -project mac/AndroidMirroring.xcodeproj -scheme AndroidMirroring \
  -configuration Release -destination 'platform=macOS' build   # build the Mac app

(cd android && ./gradlew :app:assembleOssDebug)       # build the Android app
# APK: android/app/build/outputs/apk/oss/debug/

scripts/interop-test.sh                               # real Swift Mac server vs real Kotlin phone client, over mutual TLS 1.3
```

`scripts/interop-test.sh` needs `JAVA_HOME` set to a JDK 21. Pass `--no-build` to skip rebuilding.

Use the Release build for everyday use and for trying it with a phone. Debug builds (`-configuration Debug`, or Run in Xcode) are for development only: they add a "Copy pairing link" menu item and log the pairing URI, which contains the pairing secret.

### Signing the Mac app (optional)

By default the Mac app is ad-hoc signed, so it builds with no Apple account. The catch: macOS treats every rebuild as a new app, so after each rebuild you get a Keychain prompt asking to use or access items: click "Always Allow". A prompt that mentions exporting a key should not appear; if it does, click Deny and report it.

To avoid them, sign with a free Personal Team. Copy `mac/Config/Local.xcconfig.example` to `mac/Config/Local.xcconfig` (gitignored), set `DEVELOPMENT_TEAM` to your team ID, and run `xcodegen` again.

### Trying it with a phone

Install the debug APK on an Android 10+ phone. In the Mac app, open the menu-bar icon and choose "Pair a phone…". A QR code appears. Either scan it from the phone app's in-app scanner, or scan it with the phone's camera app, which opens an `anmirror://pair` link in the app. Confirm that the same code shows on both devices.

## Requirements (planned)

- macOS 14 Sonoma or later
- Android 10 or later. Mirroring and control need Android 11+ and a one-time developer-mode step.

## License

Planned: Apache-2.0 (see [PRD §11](docs/PRD.md#11-decisions)).
