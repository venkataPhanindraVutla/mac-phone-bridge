# Android Mirroring: Product Requirements

Status: **Approved** · Last updated: 2026-10-27

Related: [Architecture](ARCHITECTURE.md) · [Versions & roadmap](ROADMAP.md)

---

## 1. Summary

Android Mirroring is an **open-source pair of native apps**:

- a **macOS app written in Swift**
- an **Android app written in Kotlin**

The two talk to each other directly, so an Android phone feels like part of the Mac. You see and act on phone notifications, move files both ways, share the clipboard, handle calls, control music, and mirror and control the phone (including apps like WhatsApp) from the Mac.

Think of it as what Apple's Continuity features (iPhone Mirroring, Handoff, Universal Clipboard, AirDrop, Continuity Camera) give iPhone owners, built for Android owners who use a Mac.

## 2. Why

- Android users on a Mac have no first-party equivalent of Apple's Continuity features.
- The existing open-source options are KDE Connect (notifications, files, clipboard, media) and scrcpy (mirroring). Users report that they feel bolted on rather than native, and they are separate tools.
- **The product's reason to exist is being native on both sides.** It should look and behave like a real Mac app (menu bar, system notifications, Finder, Share menu, standard shortcuts) and a real modern Android app, with everything in one place.

## 3. Who it's for

**Primary:** everyday people who own an Android phone and a Mac. Most are not developers, so the core features must not need developer settings.

**Secondary:** developers and power users who are comfortable enabling developer mode to unlock mirroring and full control.

**Contributors:** an open-source community, so the code, protocol and docs must be approachable.

## 4. Goals, non-goals, anti-goals

### Goals
1. Every v1 feature works between one Mac and one paired Android phone on the same network, without any cloud service.
2. The core features (everything except mirroring and control) work with **only the Android app installed**. No developer mode, no cable.
3. Mirroring and control work after a **one-time, guided** developer-mode step.
4. It feels native on both platforms: system notifications, the menu bar, Finder integration, the Share menu, Android share sheet, Quick Settings tiles.
5. Pairing takes under 2 minutes for a non-developer.

### Non-goals (for now)
- **Reading or sending SMS/RCS text messages.** This is the user's explicit decision. One-time-code copy works from notifications only (see F-09).
- Windows or Linux desktop apps.
- Multiple phones connected at the same time. You can pair several, but one is active.
- A phone connected to several Macs at the same time. A phone can be paired with several Macs, but it connects to one at a time (builder's call — see §11).
- Working over the internet when the two devices are on different networks.
- iPhone support.
- Distribution through the Mac App Store. Mac-side input injection is incompatible with its sandbox (see Architecture §9).

### Anti-goals (it fails if it does these, even if everything else works)
- Sends any user data to a server: no account, no cloud relay, no analytics or telemetry by default.
- Needs developer mode for the basic features.
- Feels like a web or cross-platform app on either side.
- Drains the phone battery noticeably when idle. Target: under 4% per day attributable to the app with no active use.
- Leaves the paired connection unauthenticated or unencrypted.

## 5. Setup levels

| Level | What's required | Unlocks |
|---|---|---|
| **Basic** | Android app installed, QR-code pairing, and the Android permissions each feature asks for when first used | Every v1 feature except those listed under Full |
| **Full** | Basic, plus a one-time **developer-mode** step: Wireless debugging, **Android 11+ only**. The app walks the user through it | Screen mirroring, Mac keyboard and mouse controlling the phone, automatic phone→Mac clipboard |

Full mode must be **optional and clearly explained**: what developer mode is, why it's needed, and how to turn it off.

## 6. Version 1 features

Each feature lists the user outcome, required behavior, setup level, and acceptance criteria. "Mac" means the macOS app and "phone" means the Android app unless stated otherwise.

### F-01 Pairing and connection *(Basic)*
- **Outcome:** pair once, and the two reconnect automatically whenever they're near each other on the same network.
- **Behavior:**
  - The Mac shows a QR code. The phone scans it, both sides confirm a short code, and they store each other's keys.
  - After that they find each other automatically.
  - A paired device can be removed from either side.
- **Acceptance:**
  - Pairing completes in under 2 minutes for a first-time user.
  - Reconnects within 10 s of both being on the same network and awake.
  - An unpaired device cannot connect.

### F-02 Phone status in the Mac menu bar *(Basic)*
- **Outcome:** see the phone's battery level and charging state, signal strength, Wi-Fi/mobile data, and connection state from the menu bar.
- **Acceptance:** values update within 30 s of a change. "Connected/disconnected" updates immediately when the connection closes (app quit, phone app stopped, and Mac sleep/wake with phones older than the 0.1 keep-alive patch; a newer phone stays connected across the Mac's sleep); within 2 minutes when the phone vanishes (75 s with phones older than the 0.1 keep-alive patch). *(Builder's call for 0.1; faster detection of a vanished phone is tracked for 0.9.)*

### F-03 Notifications on the Mac, with actions *(Basic)*
- **Outcome:** phone notifications appear as native Mac notifications.
- **Behavior:**
  - Mac notifications show the app name and icon, title, text and image where available.
  - The notification's own action buttons work, including **inline reply** (for example a WhatsApp reply).
  - Dismissing a notification on either device dismisses it on the other.
  - Per-app on/off control lives in Mac settings.
  - Ongoing and media notifications are not duplicated; F-07 handles media.
- **Acceptance:**
  - A notification reaches the Mac within 1 s on the same network.
  - Inline reply sends from the Mac.
  - Dismissal syncs both ways.

### F-04 Files both ways *(Basic)*
- **Outcome:** move files between Mac and phone by dragging and sharing.
- **Behavior:**
  - **Mac → phone:**
    - drag files onto the menu-bar icon, the app window or the mirror window
    - or use the Mac Share menu → "Send to <phone>"
    - Files land in the phone's `Download/Android Mirroring` folder, and the phone shows a notification.
  - **Phone → Mac:**
    - Android share sheet → "Send to Mac"; files land in `~/Downloads`
    - **and** the phone appears as a location in **Finder's sidebar**. Its storage can be browsed, and files dragged out to copy them or dragged in to copy them to the phone.
  - Progress and cancel are shown on both sides. Large files (multi-GB) are supported.
- **Acceptance:**
  - A 1 GB file transfers at ≥ 20 MB/s on 5 GHz Wi-Fi.
  - An interrupted transfer reports failure clearly. Resume is nice-to-have.

### F-05 Shared clipboard (text) *(Basic, automatic both ways in Full)*
- **Behavior:**
  - **Mac → phone:** copying text on the Mac makes it available on the phone automatically.
  - **Phone → Mac:**
    - In **Basic**, Android 10+ blocks background apps from reading the clipboard, so the user sends it with a Quick Settings tile, a notification action, or "Send to Mac".
    - In **Full**, it's automatic.
  - Text only in v1. A size cap is set by the builder.
- **Acceptance:** text copied on one side can be pasted on the other within 1 s, given the trigger above.

### F-06 Calls *(Basic)*
- **Outcome:** see incoming calls on the Mac and act on them.
- **Behavior:**
  - The Mac shows incoming calls with the caller's name (from F-14) and number, with **Answer** and **Decline**.
  - During a call: **Mute** and **Hang up**.
  - Missed-call notifications appear.
  - **In v1, call audio stays on the phone,** or on whatever headset is connected to it (builder's call — see §11).
- **Acceptance:** answering or declining from the Mac works on Android 10–16.

### F-07 Music / media controller *(Basic)*
- **Outcome:** control whatever is playing on the phone from the Mac.
- **Behavior:**
  - The Mac menu bar shows the current track, artist, artwork and the app playing.
  - Play/pause, next, previous, seek and volume.
  - The phone's media also shows in macOS **Now Playing**, so the Mac's media keys and Control Center can control it while connected.
- **Acceptance:** commands take effect on the phone within 300 ms.

### F-08 Find my phone *(Basic)*
- **Behavior:** a "Ring phone" button makes the phone ring at full volume, **even on silent or Do Not Disturb**, until it's stopped on either device.

### F-09 One-time codes *(Basic)*
- **Behavior:**
  - When a phone notification contains a verification code, the Mac notification offers **"Copy code"**.
  - Detection runs only on notification text the user has already allowed through F-03. **The app never requests SMS access.**

### F-10 Send to Mac / Send to phone *(Basic)*
- **Behavior:**
  - **Links:** sharing a link from either device opens it in the other device's default browser.
  - **Text and files:** sharing them routes to F-05/F-04.
  - Sharing comes from the Android share sheet and the macOS Share menu.

### F-11 Do Not Disturb sync *(Basic, with platform limits)*
- **Behavior:**
  - Turning on Do Not Disturb on the phone turns on a Mac Focus.
  - Turning on a Focus on the Mac turns on phone DND.
  - **Platform limit:** macOS has no public API to set a Focus. The Mac side asks the user to install a provided Shortcut, which the app runs. If the Shortcut isn't installed, phone → Mac sync is off and the UI says so.
- **Acceptance:** both directions work once the Shortcut is installed, within 5 s.

### F-12 Instant screenshots *(Basic)*
- **Behavior:** a screenshot taken on the phone appears on the Mac within seconds. The user chooses Desktop, `~/Downloads`, or the clipboard (default: Desktop).

### F-13 Recent photos browser *(Basic)*
- **Behavior:** a Mac window shows the phone's recent photos and videos as a grid. They can be dragged out to Finder or other apps, or saved.
- **Acceptance:** the newest 200 items load as thumbnails in under 3 s.

### F-14 Caller ID and contacts *(Basic)*
- **Behavior:**
  - Phone contacts sync to a **private store inside the Mac app**. They are not written into the Mac Contacts app in v1.
  - The store is used for caller names (F-06) and notification enrichment.
  - The user can turn this off and wipe it.

### F-15 Auto-lock the Mac when the phone walks away *(Basic, opt-in)*
- **Behavior:**
  - When the paired phone's Bluetooth signal stays weak past a threshold for a set time, the Mac locks.
  - The threshold is adjustable, with a "test" mode.
  - **Never unlocks the Mac;** macOS doesn't allow that.
- **Acceptance:** no false locks in 8 hours of normal desk use at the default setting.

### F-16 Phone as presentation remote / trackpad *(Basic)*
- **Behavior:** a phone screen offers:
  - **Trackpad mode:** moves the Mac pointer, click, scroll.
  - **Remote mode:** next/previous slide, laser-pointer style pointer.

  The Mac needs the macOS Accessibility permission for this.

### F-17 Screen mirroring, with full control *(Full)*
- **Outcome:** use WhatsApp, or any app, from the Mac.
- **Behavior:**
  - A native Mac window shows the phone screen live, with **phone audio played on the Mac** (Android 11+).
  - Mac **mouse/trackpad → touch:** click = tap, scroll = scroll, drag = swipe, plus a gesture for long-press.
  - **Keyboard:** typing (including non-English text), shortcuts.
  - Toolbar/menu buttons for **Back, Home, Recents**, rotate and volume, and a resizable window.
  - Optionally **turn the phone's screen off** while mirroring.
  - Files dropped onto the window go through F-04.
- **Acceptance:**
  - On reference phones (§10) over 5 GHz Wi-Fi: under 80 ms end-to-end delay, 60 fps at up to about 1080p (long edge ~1920 px), scaled to the window.
  - Other phones and weaker networks adapt resolution and bitrate down rather than missing the delay target.
  - Typing into WhatsApp works, including emoji.
- **Known limit:** apps that block screenshots (banking, some video apps) show black.

### F-18 Mac keyboard and mouse control *(Full)*
- Covered by F-17 in v1: control happens through the mirror window.

## 7. Version 2 features (later)

| ID | Feature | Notes |
|---|---|---|
| F-20 | Phone as Mac **webcam** | Appears as a camera in any Mac app (macOS Camera Extension) |
| F-21 | Phone as Mac **microphone** | Appears as an audio input device |
| F-22 | **One-click hotspot** | Turn on the phone's hotspot and join it from the Mac. Needs Full mode on most phones |
| F-23 | *(Research)* Call audio on the Mac | Talk through the Mac's mic and speakers during phone calls |

## 8. Non-functional requirements

- **Privacy:**
  - All data stays on the two devices, and nothing is relayed through servers.
  - No telemetry by default. If optional crash reporting is ever added, it must be opt-in.
- **Security:**
  - Mutually authenticated, encrypted connection with keys pinned at pairing.
  - The Full-mode helper only accepts commands from the paired Mac over that connection.
- **Battery:** under 4% per day idle on the phone (see anti-goals). Discovery and keep-alive must be designed for this.
- **Reliability:** reconnects automatically after sleep, a network change, or the app being killed by the phone's battery saver. Shows clear state when it can't.
- **Accessibility:**
  - Mac UI fully usable with VoiceOver and the keyboard.
  - Android UI fully usable with TalkBack.
  - (Reading the *mirrored* phone screen with VoiceOver is out of scope.)
- **Localization:** English at launch, with all strings externalized so the community can translate.
- **Open source:**
  - A clear license (see §11).
  - CONTRIBUTING guide.
  - A documented protocol so others can build compatible clients.

## 9. Platform support

- **macOS:** 14 Sonoma or later, Apple silicon and Intel.
- **Android:**
  - 10 (API 29) or later for Basic.
  - 11 or later for Full mode (mirroring and control). Android 10 phones get Basic only.
- **Phone makers:** tested on Pixel, Samsung, Xiaomi, OnePlus and Motorola at minimum. Phone-maker quirks (aggressive battery savers, extra developer toggles) must be documented in-app.

## 10. Success measures

Performance targets are measured on **reference phones**: for now, the phones the project owner has on hand, plus a recent Pixel and a recent Samsung Galaxy flagship when available. All on 5 GHz Wi-Fi. On other phones they're goals, not release gates.

- Pairing: under 2 minutes, with ≥ 90% success on first try in user testing.
- Notifications: under 1 s on the same network.
- Mirroring: under 80 ms delay, 60 fps.
- Stability: under 1 unexpected disconnect per hour of active use.
- Open source: the README gets a new contributor building both apps in under 30 minutes.

## 11. Decisions

**User's decisions**
- Native apps: Swift on Mac, Kotlin on Android, talking to each other directly.
- Open source.
- v1 scope:
  - notifications + actions, files both ways, clipboard, calls, music controller, Mac keyboard/mouse control, mirroring (WhatsApp etc.)
  - the "easy" extras: F-02, F-08–F-12
  - the "medium" extras except text messages: F-13–F-16
- **No reading text messages.**
- v2 scope: webcam, microphone, hotspot.
- Name: Android Mirroring.
- **Team:** the project owner and Claude build v1 together. A second contributor (with their own Claude partner) joins after v1 is released.
- **Distribution order:** GitHub and F-Droid first. Google Play comes later, after the project becomes a nonprofit.
- **Apple Developer account:** none today. The plan is to become a nonprofit later, which may qualify for Apple's fee waiver. Until then, everything is built and tested with a free Apple ID.

**Builder's calls in this document** (open to change)
- **Call audio stays on the phone in v1.** Moving call audio to the Mac is research for v2 (F-23).
- Two setup levels (Basic / Full), so non-developers get most features.
- One-time codes come from notifications only.
- Contacts stay in the app's private store, not in Mac Contacts.
- The phone appears in the Finder sidebar for browsing files (F-04).
- Platform minimums (§9) and performance targets (§10).
- License: **Apache-2.0**. It's compatible with reusing parts of scrcpy (also Apache-2.0); see Architecture §10.
- Repo folder `Android-Mirroring`, with a hyphen, to avoid spaces in build paths.
- **Full mode is Android 11+ only.** An Android 10 path would need a USB cable and `adb` on the Mac after every phone restart, which isn't "one-time".
- **A phone connects to one Mac at a time,** though it can be paired with several.
- **Performance targets are release gates on reference phones only** (§10); elsewhere quality adapts.
- **Mirroring stays in 1.0** (the user's decision). If the 0.1 spike misses its targets, the Full-mode design is reworked before 0.2 starts, rather than mirroring being dropped.
- **Reference phones for now are the phones the project owner has on hand.** A recent Pixel and a recent Samsung are added when available (§10).
- **If there's still no paid Apple account at 1.0,** the Mac app ships un-notarized on GitHub with clear "Open Anyway" install steps. In that case, the Finder sidebar and Share menu extensions may be left out of the release build (Architecture §4).
- **Play-ready from the start:** features that rely on Play-restricted permissions (call log, All files access, answering calls) sit behind capability switches. A later Play build can then remove or replace them without a rewrite (Architecture §5).

## 12. Open questions

1. **The name and the Android trademark.** "Android" is a Google trademark. Google's brand guidelines generally allow "… for Android" but discourage "Android" as the leading word of a product name. That matters for the later Play Store listing. Decide before public launch.

## 13. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Phone battery savers kill the background service | Disconnects, missed notifications | Foreground service of type `connectedDevice`; per-maker guidance screen; reconnect logic |
| Phone-maker restrictions on input injection (e.g. Xiaomi's extra toggle) | Full mode fails on some phones | Detect it and show maker-specific instructions |
| Wireless debugging turns off after reboot or network change | Full mode needs re-arming | One-tap re-arm flow on the phone (Architecture §6) |
| macOS limits: no public API to set a Focus or to lock the screen | F-11 and F-15 are fragile | Shortcut-based Focus; documented lock method with fallback |
| Google Play policy on call-log, storage and call-answering permissions | Harder Play listing | GitHub/F-Droid first; Play-ready capability switches |
| No paid Apple account at release | Mac download blocked by default; Accessibility permission may reset on updates | "Open Anyway" install guide; get the account (or nonprofit waiver) as soon as possible |
| The trademark (open question 1) | Rename later | Decide before launch |
