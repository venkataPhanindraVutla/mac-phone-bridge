# Android Mirroring

**Your Android phone, part of your Mac.** An open-source pair of native apps (Swift on macOS, Kotlin on Android) that brings Continuity-style features to Android users on a Mac.

Website: https://venkataphanindravutla.github.io/mac-phone-bridge/

> **Status: milestone 0.5 is code-complete and waiting for checks on real devices.** On top of 0.1 (pairing, a secure connection, phone status in the menu bar, find my phone), 0.2 (notifications, one-time codes, contacts, calls) and 0.3 (clipboard, files, screenshots, photos, browsing your phone's files), 0.4 added control and context (a music controller, Do Not Disturb and Focus sync, auto-lock when you walk away, the phone as a trackpad and presentation remote), and 0.5 adds Full mode: the phone's screen in a Mac window, controlled with the Mac's mouse and keyboard. Everything that depends on a real phone or Mac is **unverified** until the owner checks in the results file are done. The other features below are planned. Results so far: [0.1 results](docs/milestones/0.1-results.md), [0.2 results](docs/milestones/0.2-results.md), [0.3 results](docs/milestones/0.3-results.md), [0.4 results](docs/milestones/0.4-results.md), [0.5 results](docs/milestones/0.5-results.md).

### What's in 0.5

- **Full mode (screen mirroring with control):** after a one-time setup on an Android 11+ phone, "Show Phone Screen" in the Mac menu opens a resizable window with the phone's screen and sound. The Mac's mouse, trackpad and keyboard control the phone, including emoji and non-English input methods. The toolbar has Back, Home, Recents, Rotate, volume, Screen Off, Mute and a Quality menu (Auto, High, Balanced, Low, H.265, and Option-click for Measure Delay). Files dropped on the window go to the phone, and the phone's clipboard reaches the Mac while the window is open. None of this has run on a real phone yet: see the owner checks in the results file.
- **How it works:** the phone app pairs with the phone's own Wireless debugging and starts a small helper (scrcpy's server, with two patches) that runs only while the Mac shows the screen. The phone copies the helper's bytes to your paired Mac over encrypted links, and the phone opens no listening network port.
- **Target:** under 80 ms and 60 fps on 5 GHz Wi-Fi (unverified: owner check b), and a lower quality, not lag, on a weaker link.
- No new Android permission for Full mode: its ADB library would imply the legacy `WRITE_EXTERNAL_STORAGE`, which the app's manifest removes, and the build fails on any permission that isn't on its allow-list. The phone's licence list gains `spake2-android` (LGPL-3.0, shipped unmodified); see [docs/licenses.md](docs/licenses.md).
- Known limits: see [0.5 results](docs/milestones/0.5-results.md#known-limitations-in-05).

### What's in 0.4

- **Music controller:** the track, artist and artwork from the phone's media player show in the Mac menu and in the Phone window's Now Playing tab (with Position and Volume sliders), and are meant to show in Control Center (unverified: owner check b). Play or Pause, Previous, Next and volume are meant to work from the menu (unverified). The Mac's media keys and AirPods taps are meant to work too, but macOS may not send them to a menu-bar app that plays no audio (unverified: owner check b). Needs notification access on the phone.
- **Do Not Disturb and Focus sync:** Focus on the Mac turns on Do Not Disturb on the phone, and the phone's Do Not Disturb turns on a Focus on the Mac. Phone to Mac needs two Shortcuts you make once (see "Focus sync" below). Whether the ad-hoc signed Contributor build can read Focus status is unverified (owner check d), and on Android 15 and later turning Focus off on the Mac is expected to leave a Do Not Disturb you turned on by hand on the phone (unverified: owner check c).
- **Auto-lock when you walk away:** the phone sends a small Bluetooth beacon, and the Mac locks when it stays away. It never unlocks the Mac, and it is deliberately conservative: it does not lock while a video, call or browser keeps the screen awake, and it needs the phone to have connected to the Mac over Wi-Fi in the last 30 minutes. No location permission. Unverified on a real lock and over a full day (owner check e).
- **Trackpad and presentation remote:** the phone moves the Mac's pointer, clicks, right-clicks, scrolls and drags, and its Remote tab has Previous, Next, a laser dot and optional volume-key slide changes. Needs the Accessibility permission, asked for only when you turn the setting on. Ad-hoc builds are expected to lose that grant on every rebuild (unverified: owner check f).
- Still no SMS or MMS access, no account and no cloud. The new Android permission is `BLUETOOTH_ADVERTISE` (older Android uses the legacy Bluetooth permissions); there is no location permission.
- Known limits: see [0.4 results](docs/milestones/0.4-results.md#known-limitations-in-04).

### What's in 0.3

- **Shared clipboard** for text, both ways. Text that a password manager marks as secret is not sent. On the phone: a Quick Settings tile, a notification action and the Share sheet.
- **Send files and links both ways:** drop files on the Phone window, use "Send File to Phone…" in the menu, or share from the phone to "Send to Mac". Transfers queue, show progress, can be cancelled, and a failed one is meant to leave no partial file (to be confirmed on devices). Files sent to the Mac land in Downloads; files sent to the phone land in `Download/Android Mirroring`. Links and text arrive as notifications.
- **Screenshots:** a screenshot taken on the phone arrives on the Mac in your Desktop, Downloads or clipboard, with a notification.
- **Recent photos:** the newest photos and videos as thumbnails on the Mac; drag them out to Finder or Mail.
- **Files tab:** browse the phone's files from the Mac's Phone window, download, upload, rename and delete. With All files access (open-source build, Android 11+) or with only the folders you pick.
- **Full build only:** the phone in Finder's sidebar (unverified, owner check h3) and "Send to Phone" in the Share menu (see "Full build" below). The Contributor build has the Files tab instead.
- Still no SMS or MMS access, no account and no cloud. Nothing from the Mac is kept on the phone except files you chose to receive.
- Known limits, such as no resume and no folder transfers: see [0.3 results](docs/milestones/0.3-results.md#known-limitations-in-03).

### What's in 0.2

- **Notifications on your Mac,** with action buttons and inline reply, a per-app filter, and dismissals that go both ways.
- **One-time codes:** a "Copy code" button on notifications that contain a sign-in code.
- **Contacts:** synced to an encrypted file on your Mac, used only for caller names; off with one switch in Settings.
- **Calls:** a panel for incoming calls, with Answer, Decline, Mute and Hang up from the Mac. Needs call-log and answer-calls access, which the open-source build asks for.
- No SMS or MMS access: the Android app asks for no SMS permission.

## What it will do (version 1)

- 🔔 **Notifications on your Mac,** with actions and inline reply (in 0.2)
- 📁 **Files both ways:** drag, Share menu, and your phone in Finder's sidebar (in 0.3)
- 📋 **Shared clipboard** for text (in 0.3)
- 📞 **Calls:** see, answer and decline from your Mac (in 0.2)
- 🎵 **Music controller,** including your Mac's media keys (in 0.4)
- 🖥️ **Screen mirroring with full control:** use WhatsApp and any app with your Mac's keyboard and mouse (in 0.5)
- Also:
  - phone status in the menu bar
  - find my phone
  - one-time-code copy (in 0.2)
  - Send to Mac / Send to phone (in 0.3)
  - Do Not Disturb sync (in 0.4)
  - instant screenshots (in 0.3)
  - recent photos (in 0.3)
  - caller ID
  - auto-lock your Mac when you walk away (in 0.4)
  - phone as trackpad / presentation remote (in 0.4)

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

### Full build (Finder sidebar and Share menu)

The build above is the **Contributor build**. It has no extensions and needs no Apple account. The **Full build** adds two extensions:

- **File Provider:** shows the phone in Finder's sidebar once it has connected with file browsing on. The entry stays while the phone is disconnected: Finder then says "Your phone isn't connected." Forgetting the phone removes it. (Unverified, owner check h3.)
- **Share:** adds "Send to Phone" to the Share menu.

Both extensions share an App Group with the app, and App Groups need a team. Set `DEVELOPMENT_TEAM` in `mac/Config/Local.xcconfig` as above. A paid team should work, but this is unverified (owner check h1). A free Personal Team may not be able to sign the App Group or the File Provider. If it can't, use the Contributor build: its Files tab in the Phone window does the same browsing.

```sh
xcodegen --spec mac/project-full.yml                  # generates mac/AndroidMirroringFull.xcodeproj
xcodebuild -project mac/AndroidMirroringFull.xcodeproj -scheme AndroidMirroring \
  -configuration Release -destination 'platform=macOS' build
```

The Full build uses the same app, plus the extensions and the code under `#if FULL_BUILD`. `mac/project.yml` stays the Contributor build.

### Trying it with a phone

Install the debug APK on an Android 10+ phone. In the Mac app, open the menu-bar icon and choose "Pair a phone…". A QR code appears. Either scan it from the phone app's in-app scanner, or scan it with the phone's camera app, which opens an `anmirror://pair` link in the app. Confirm that the same code shows on both devices.

### Full mode

Full mode needs Android 11 or later and a one-time setup on the phone; the phone's own **Full mode** screen walks you through it. In short:

1. On the phone's home screen, tap "Set up Full mode" under "Allow your Mac to show this screen".
2. Turn on Developer options and Wireless debugging, tap "Pair device with pairing code", and type the code into the notification from Android Mirroring when it asks.
3. When the screen says "Full mode is ready.", choose "Show Phone Screen" in the Mac menu.

After a reboot or a change of Wi-Fi network, tap "Re-enable Full mode" on the phone. To turn Full mode off, turn off Wireless debugging or Developer options. On some phones (vivo, OPPO, OnePlus, Xiaomi and others) the screen shows one more switch to turn on, or taps and typing from the Mac won't work. Whether it works on your phone is unverified until the owner checks in [the 0.5 results](docs/milestones/0.5-results.md) are done.

### Focus sync

Focus on the Mac and Do Not Disturb on the phone can follow each other. Any Focus on the Mac counts as "on". Turn on "Sync Focus with <phone>" in the Mac app's Settings, and "Sync Do Not Disturb with your Mac" in the phone app.

- **Mac to phone:** the Mac reads whether a Focus is on. macOS asks once for Focus status access when you turn the setting on.
- **Phone to Mac:** macOS has no public way for an app to turn Focus on, so the Mac app runs two Shortcuts that you make once:

1. Open the Shortcuts app and create a new shortcut.
2. Add the action “Set Focus”, choose Do Not Disturb, and set it to turn On.
3. Name the shortcut “Android Mirroring Focus On”.
4. Create a second shortcut that turns Do Not Disturb Off, named “Android Mirroring Focus Off”.
5. Come back here and click Check Again.

"Here" is the Focus section of the Mac app's Settings.

On Android 15 and later, the phone's Do Not Disturb from the Mac is an app "mode" that only the app can switch off, so turning Focus off on the Mac is expected to leave a Do Not Disturb you turned on by hand on the phone (unverified on a device: owner check c). Below Android 15 it is meant to clear it.

Whether the ad-hoc signed Contributor build can read Focus status is not yet confirmed (owner check). If it can't, Settings says "This build of Android Mirroring can't read Focus status." and only the phone-to-Mac direction works.

## Requirements (planned)

- macOS 14 Sonoma or later
- Android 10 or later. Mirroring and control need Android 11+ and a one-time developer-mode step.

## License

Planned: Apache-2.0 (see [PRD §11](docs/PRD.md#11-decisions)).
