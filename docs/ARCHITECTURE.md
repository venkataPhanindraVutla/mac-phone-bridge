# Android Mirroring: Architecture

Status: **Approved** · Last updated: 2026-10-27

Related: [PRD](PRD.md) · [Versions & roadmap](ROADMAP.md)

This document describes how the PRD gets built. Items marked **(builder's choice)** are left to whoever implements them, within the constraints given.

---

## 1. Big picture

```
┌──────────────────────── Mac (Swift) ────────────────────────┐
│  Menu bar app (SwiftUI MenuBarExtra + AppKit windows)        │
│   ├─ Connection core: discovery, pairing, TLS, framing       │
│   ├─ Feature modules: notifications, files, clipboard,       │
│   │   calls, media, status, find, OTP, share, DND,           │
│   │   screenshots, photos, contacts, auto-lock, remote,      │
│   │   mirroring                                              │
│   ├─ File Provider extension → phone in Finder sidebar       │
│   └─ Share extension → "Send to <phone>"                     │
└───────────────┬──────────────────────────────┬──────────────┘
     control + bulk (TLS 1.3 over TCP)      mirror A/V + input
                │  same LAN (mDNS)              │ (Full mode)
┌───────────────┴──── Android (Kotlin) ────────┴──────────────┐
│  Companion app                                               │
│   ├─ Foreground service (connectedDevice): connection core   │
│   ├─ NotificationListenerService (notifications + media)     │
│   ├─ Feature modules (calls, files, clipboard, contacts, …)  │
│   ├─ Share target, Quick Settings tiles, BLE advertiser      │
│   └─ Full-mode bootstrapper (wireless-debugging launcher)    │
│                                                              │
│  Full-mode helper (runs as the `shell` user via app_process) │
│   ├─ Screen capture → MediaCodec H.264/H.265                 │
│   ├─ Audio capture (Android 11+)                             │
│   ├─ Input injection (touch, scroll, keys, text)             │
│   └─ Clipboard read/write, display power                     │
└──────────────────────────────────────────────────────────────┘
```

**The main idea:**
- An ordinary Android app can do everything in Basic mode.
- Only mirroring and control need the **shell-privileged helper**. That is the same technique scrcpy uses, and it's why Full mode needs developer settings.
- Apple's own iPhone Mirroring uses an equivalent split: a normal companion layer for notifications and pairing, and a privileged system service for screen capture and input.

## 2. Repository layout

```
/mac            Xcode project; app, File Provider ext, Share ext; Swift packages for core modules
/android        Gradle project; :app (companion), :helper (full-mode helper), :core modules
/protocol       Message schema (.proto), protocol spec, conformance test vectors
/docs           PRD, architecture, roadmap, contributor docs
/scripts        Build, release, latency-measurement tooling
```

**Protocol definitions live in one place (`/protocol`).** The Swift and Kotlin code is generated from them, so both sides can't drift apart.

## 3. Discovery and connection

### 3.1 Discovery
- **LAN:** the Mac advertises a Bonjour/mDNS service, `_anmirror._tcp` (builder's choice of exact name). The phone discovers it with Android NSD.
  - The advertisement contains **no personal data**, only a random rotating ID that paired devices can recognize.
- **Bluetooth LE:** the phone advertises a rotating identifier derived from the pairing key. The Mac uses it for:
  - proximity (F-15 auto-lock)
  - a "phone is nearby, try connecting" hint
- **Same network required in v1.** Phone-hotspot fallback is the v2 hotspot feature (F-22).

### 3.2 Pairing (F-01)
1. **The Mac shows a QR code** containing:
   - the Mac's certificate fingerprint
   - its addresses and port
   - a one-time pairing secret
   - the protocol version
2. **The phone connects** over TLS, checks the Mac's fingerprint, and proves it knows the secret. It then sends its own self-signed certificate.
3. **Both show a 6-digit confirmation code** derived from both keys. The user confirms on both devices.
4. **Each side stores the other's certificate:**
   - on the Mac, in the Keychain
   - on Android, in Android Keystore plus encrypted preferences

   From then on, connections are **mutual TLS 1.3 with pinned certificates.** Anything else is rejected.

### 3.3 Connections and channels
- **Control connection:** one long-lived TLS connection.
  - Carries length-prefixed **Protocol Buffers** messages in an envelope: `{channel, id, reply_to, type, payload}`.
  - Used for everything small: notifications, clipboard, calls, media, status, settings.
  - Keep-alive is tuned for battery (builder's choice; it must meet the 2%/day goal): Mac-driven ping every 30 s (`liveness.v1`), phone answers, TCP keepalive on all sockets.
  - On Mac wake a `liveness.v1` session is kept and pinged at once; other connections close as in 0.1. A phone whose long session the Mac closed dials again at once (SPEC §7).
- **Bulk connections:** a separate TLS connection per file transfer, or per batch (F-04, F-12, F-13). Big files then never block small messages.
- **Mirror connections (Full mode):** separate TLS connections for video, audio and input (see §6).
- **Capabilities handshake:** on connect, both sides exchange `{protocol_version, app_version, capabilities[], setup_level}`.
  - Features are turned on only when both sides support them. Old and new versions then work together safely.
  - Apple does the same thing (`serverSupportsCapabilities`).

## 4. Mac app

- **Tech:**
  - Swift 6, SwiftUI with AppKit where SwiftUI falls short (mirror window, input capture, drag and drop).
  - Minimum macOS 14.
- **App shape:**
  - a menu-bar app (`MenuBarExtra`) with a settings window
  - a device window (photos, files, find phone)
  - a mirror window
  - "Open at login" via `SMAppService`.
- **Modules (Swift packages):**
  - `ConnectionCore`: Network.framework TLS, Bonjour, pairing, Keychain.
  - `Protocol`: generated code from `/protocol`.
  - One package per feature.
- **Feature notes:**
  - **Notifications (F-03, F-09):**
    - Use `UNUserNotificationCenter`. Action buttons map to `UNNotificationAction`, and inline reply to `UNTextInputNotificationAction`.
    - Categories are registered on the fly per unique action set (cached).
    - The app icon is cached per Android package.
    - One-time-code detection happens on the Mac, from notification text.
  - **Files (F-04):**
    - **File Provider extension** (`NSFileProviderReplicatedExtension`) shows the phone in Finder's sidebar. It talks to the main app over XPC / an App Group.
    - The **Share extension** gives "Send to <phone>".
    - Drag targets: the menu-bar icon, the device window and the mirror window.
  - **Media (F-07):** `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` while connected, so media keys and Control Center work.
  - **DND (F-11):** reading Mac Focus uses `INFocusStatusCenter`. Setting it runs a user-installed Shortcut (`shortcuts run`), because there's no public API.
  - **Auto-lock (F-15):**
    - CoreBluetooth scanning for the phone's rotating identifier, with an RSSI threshold and smoothing.
    - The lock method is **builder's choice**. It must be tested on every supported macOS version and must not need admin rights.
  - **Trackpad/remote (F-16):** injected with `CGEvent`. Needs the macOS **Accessibility** permission, requested only when the feature is turned on.
  - **Mirroring (F-17):**
    - `VTDecompressionSession` (hardware H.264/H.265) → `AVSampleBufferDisplayLayer` in a resizable window.
    - Audio through `AVAudioEngine`.
    - `NSEvent` capture, translated to touch, scroll and key events. Text input goes through `NSTextInputClient`, so non-English input methods and emoji work.
- **Distribution:**
  - Target: Developer ID–signed, notarized DMG on GitHub Releases, plus a Homebrew cask.
  - **Until a paid Apple account exists** (PRD §11): an un-notarized DMG on GitHub with "Open Anyway" install steps and no Homebrew cask. Release builds then use the contributor configuration (no extensions) if the extensions can't be signed for distribution.
  - Sparkle for updates (builder's choice of update mechanism).
  - Not the Mac App Store (see §9).
- **Contributor builds:** the File Provider and Share extensions need App Groups tied to a paid Apple Developer team. So there is also a **contributor build configuration**: extensions off, local signing. Anyone can build and run the main app without a paid account.
- **One Mac at a time:** a phone keeps one active connection. If a second paired Mac is nearby, the phone stays with the current one until the user switches from the phone or the menu bar.

## 5. Android app (Basic mode)

- **Tech:**
  - Kotlin, Jetpack Compose, coroutines.
  - `minSdk 29` (Android 10), `targetSdk` = latest stable.
- **Process model:**
  - A **foreground service** of type `connectedDevice` holds the connection, with a quiet persistent notification as Android requires.
  - Everything is restarted on boot and after the service is killed.
  - Per-maker guidance screens cover battery-saver exemptions.
  - After pairing, the app asks for the battery-optimisation exemption (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`), and the home screen keeps a row until it is granted.
  - A **watchdog** alarm (inexact `setAndAllowWhileIdle`, every 15 min, re-armed on each fire) restarts the service if it is gone while a Mac is paired. Without the exemption it posts a "Tap to reconnect" notification instead.
- **Build flavors:** one `oss` flavor for GitHub and F-Droid now. Features that depend on Play-restricted permissions (`READ_CALL_LOG`, `MANAGE_EXTERNAL_STORAGE`, `ANSWER_PHONE_CALLS`) are behind capability switches. A later `play` flavor can then drop them from its manifest and fall back:
  - number from the call notification instead of the call log
  - picked folders instead of All files access
  - call actions from the call notification
- **Each permission is requested only when its feature is turned on:**

| Feature | Android mechanism | Permission / access |
|---|---|---|
| F-03 Notifications | `NotificationListenerService`; actions via `PendingIntent.send()`; replies via `RemoteInput` | Notification access (Settings screen) |
| F-07 Media | `MediaSessionManager.getActiveSessions()` (allowed through notification access); `MediaController` transport controls | same as above |
| F-06 Calls | `TelephonyCallback` for call state; `TelecomManager.acceptRingingCall()` / `endCall()`; mute through the call's notification actions or `AudioManager` | `READ_PHONE_STATE`, `ANSWER_PHONE_CALLS`, `READ_CALL_LOG` (for the number) |
| F-14 Contacts | `ContactsContract`, with incremental sync | `READ_CONTACTS` |
| F-02 Status | `BatteryManager`, `TelephonyManager` signal strength, `ConnectivityManager` | `ACCESS_NETWORK_STATE` only |
| F-08 Find phone | Play on the alarm stream at full volume; override DND | Notification-policy access |
| F-11 DND sync | `NotificationManager.setInterruptionFilter()` and a listener for changes | Notification-policy access |
| F-12 Screenshots | `ContentObserver` on MediaStore, filtered to the screenshots folder | `READ_MEDIA_IMAGES` (13+) / `READ_EXTERNAL_STORAGE` (≤12) |
| F-13 Photos | MediaStore queries plus thumbnails | `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` (with Android 14 partial access handled) |
| F-04 Files in | MediaStore Downloads → `Download/Android Mirroring` | none (on 10+) |
| F-04 Finder browsing | Whole-storage browsing needs **All files access** (`MANAGE_EXTERNAL_STORAGE`). Fallback: user-picked folders via the Storage Access Framework | All files access (opt-in) |
| F-05 Clipboard | Writing works in the background. Reading only from the foreground → Quick Settings tile / notification action / share target (Basic) | none |
| F-10 Share | Share-target activity ("Send to Mac"). **Opening a Mac→phone link** needs a tap on a notification, because Android blocks background apps from opening screens | none |
| F-15 / proximity | BLE advertising from the foreground service | `BLUETOOTH_ADVERTISE` |
| F-16 Remote/trackpad | An activity with gesture surface that sends events to the Mac | none |

## 6. Full mode (mirroring and control)

### 6.1 Starting the helper
The helper is a small Java/Kotlin program packaged inside the APK. It is started with `app_process` **as the `shell` user**, which is allowed to capture the screen and inject input. **Full mode is Android 11+ only** (PRD §11); there is no USB/`adb`-from-the-Mac path in v1.

- **How it starts (no computer needed):**
  1. The user turns on Developer options → Wireless debugging. The app shows step-by-step help.
  2. The companion app pairs with the phone's **own** wireless-debugging service on localhost, using the pairing code (entered via a notification input field). The open-source apps Shizuku and LADB do the same.
  3. It then uses that ADB connection to launch the helper.
  4. After a reboot or network change, wireless debugging may switch off. The app shows a one-tap "Re-enable Full mode" flow.

### 6.2 Helper ↔ app ↔ Mac
- The helper and the companion app talk over a **local socket** protected by a random token, which the app passes at launch.
- For speed, the helper opens the **mirror connections straight to the Mac** (video, audio, input), authenticating with a short-lived session token the Mac issued over the control connection.
- Relaying everything through the app is an acceptable simpler first step **(builder's choice)**, as long as it meets the 80 ms target.

### 6.3 Capture, encode, inject
- **Video:**
  - Display mirroring or a virtual display → `MediaCodec` hardware encoder (H.264 baseline; H.265 when both sides support it).
  - Bitrate and resolution adapt to the network.
  - Keyframe on request (window resize, packet loss).
- **Audio (Android 11+):** captured as scrcpy does, encoded with Opus or AAC (builder's choice), and played on the Mac.
- **Input:**
  - Pointer/touch, scroll and key events are injected through `InputManager`.
  - Text goes in through key-character mapping, with a clipboard-paste fallback for characters that can't be typed (emoji).
  - Back/Home/Recents/volume are sent as key events.
- **Screen off while mirroring:** sets the display's power mode the way scrcpy does, with version-specific paths.
- **Clipboard (F-05 Full):** the helper watches the clipboard and pushes changes to the Mac automatically.

### 6.4 Reuse
**Reuse code from scrcpy** for capture, encoding, injection and display control. It's Apache-2.0, battle-tested, and handles many Android-version quirks. Keep its NOTICE/attribution. **Do not copy KDE Connect code;** it's GPL and incompatible with Apache-2.0.

## 7. Security model

- **Trust:** only the paired device's pinned certificate is accepted. The pairing secret is single-use and expires after 5 minutes.
- **Keys:** Mac Keychain; Android Keystore.
- **Encryption:** everything in transit is TLS 1.3, including mirror streams.
- **Full-mode helper:**
  - listens only on localhost / the authenticated session
  - refuses commands without the token
  - exits when the session ends or the companion app dies
- **No network services are exposed** except the authenticated listener, and the Bonjour advertisement carries no personal data.
- **Data at rest:** notification history, contacts and thumbnails are stored only as long as needed, encrypted on the Mac (Keychain-held key), and can be wiped from settings. Unpairing wipes them.
- **Threat model to write early:** a malicious device on the same LAN; a stolen unlocked phone; the helper running after the user turned Full mode off.

## 8. Testing

- **Protocol conformance:** shared test vectors in `/protocol`, run by both the Swift and Kotlin test suites.
- **Unit tests** per module. UI tests for pairing and settings.
- **Device matrix:**
  - Pixel, Samsung, Xiaomi, OnePlus, Motorola
  - Android 10, 11, 13, 14, 15, 16
  - macOS 14, 15, 26, on Apple silicon and Intel
- **Measured targets:** a latency harness in `/scripts` (e.g. flashing timestamp on the phone, captured on the Mac) checks the 80 ms mirroring and 1 s notification targets. Battery is checked with Android's battery stats over an idle 24 h.

## 9. Constraints worth knowing

- **Mac App Store:** sending input events (`CGEvent`) and the auto-lock approach don't fit the App Store sandbox, hence direct distribution.
- **Android background limits:**
  - No background clipboard reading.
  - No opening screens from the background.
  - Foreground-service type rules on Android 14+.
  - The design above works within all of these.
- **macOS limits:**
  - No public API to set a Focus or lock the screen.
  - Notification categories must be registered ahead of time; handled by registering them on the fly.
- **Phone-maker differences:** battery savers and extra developer toggles (e.g. Xiaomi's "USB debugging (Security settings)" for input injection). Detect them and guide the user.

## 10. Licensing

- **Project license:** Apache-2.0 (builder's call in the PRD).
- **Third-party:** scrcpy (Apache-2.0) is OK to reuse with attribution; swift-protobuf and protobuf-kotlin (BSD-3); Sparkle (MIT).
- **Avoid:** GPL code such as KDE Connect.

## 11. Left to the builder

- Exact protocol message definitions (within §3.3's envelope and capabilities rules).
- Keep-alive timing; bitrate and resolution policy; audio codec.
- Auto-lock method on macOS.
- Direct vs. relayed mirror connections (§6.2), as long as the targets are met.
- UI design details on both platforms, within "native look and feel" (PRD §2).
