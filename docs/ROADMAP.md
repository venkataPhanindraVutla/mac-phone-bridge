# Android Mirroring: Versions & Roadmap

Status: **Approved** · Last updated: 2026-10-27

Related: [PRD](PRD.md) · [Architecture](ARCHITECTURE.md)

**Who builds it:** the project owner and Claude through v1, one milestone at a time, doing the Mac and Android sides of each milestone together. A second contributor and their Claude partner join after the v1 release.

Feature IDs (F-xx) refer to the [PRD](PRD.md). The order within v1 is a **builder's call**: foundation first, the riskiest work proven early, and features grouped by the Android permissions they share. There are no dates; each milestone ends when its exit criteria pass.

---

## Version 1 (1.0)

### 0.1 Foundation + risk spike
- Repo, CI for both apps, `/protocol` with code generation for Swift and Kotlin.
- **F-01** Pairing and connection: QR code, pinned TLS, auto-reconnect, capabilities handshake.
- **F-02** Phone status in the menu bar.
- **F-08** Find my phone.
- **Risk spike (throwaway):** prove the Full-mode path on a real Android 11+ phone:
  - on-device wireless-debugging launch of the helper
  - 60 fps mirroring at under 80 ms
  - tap and type injection

  This is the riskiest part of the product; learn early whether the plan in Architecture §6 holds.
- **Exit:** a non-developer pairs in under 2 minutes; reconnects after sleep and network change; spike results written up.
- **If the spike misses its targets** on the reference phones: rework the Full-mode design (Architecture §6) before 0.2 starts. Mirroring stays in 1.0.

### 0.2 Notifications & calls
- **F-03** Notifications with actions, inline reply, dismissal sync, per-app filtering.
- **F-09** One-time-code copy, from notification text only.
- **F-14** Contacts sync to the private store, for caller ID.
- **F-06** Calls: incoming call UI with caller name, answer/decline/mute/hang up, missed calls. Audio stays on the phone.
- **Exit:** notifications arrive in under 1 s; WhatsApp reply from the Mac works; call answer/decline works on Android 10–16 test phones.

### 0.3 Sharing & files
- **F-05** Clipboard: Mac → phone automatic; phone → Mac via tile, notification action or share (Basic).
- **F-10** Send to Mac / Send to phone (links, text, files).
- **F-04** Files both ways: drag to the menu bar or window, Share extension, Android share sheet, **phone in the Finder sidebar** (File Provider).
- **F-12** Instant screenshots.
- **F-13** Recent photos browser.
- **Exit:** a 1 GB file transfers at ≥ 20 MB/s; Finder browsing works with All files access and with picked folders.

### 0.4 Control & context
- **F-07** Media controller plus macOS Now Playing / media keys.
- **F-11** DND sync (with the provided Shortcut).
- **F-15** Auto-lock the Mac on walk-away (opt-in).
- **F-16** Phone as trackpad / presentation remote.
- **Exit:** media commands take effect in under 300 ms; no false auto-locks in 8 h of desk use.

### 0.5 Full mode: mirroring & control
- Full-mode setup flow (Android 11+): guided wireless debugging, one-tap re-enable, maker-specific guidance.
- **F-17** Screen mirroring with audio, mouse/keyboard control, Back/Home/Recents, rotate, screen-off option, drop files onto the window.
- **F-05** Automatic phone → Mac clipboard in Full mode.
- **Exit:** under 80 ms and 60 fps on the reference phones over 5 GHz Wi-Fi; typing (including emoji) into WhatsApp works; works (with adaptive quality) across the device matrix.

### 0.9 Beta → 1.0
- Hardening across the device matrix (Architecture §8).
- Battery under 2%/day idle.
- VoiceOver/TalkBack pass; strings ready for translation.
- Threat-model review.
- Release pipeline: Mac DMG on GitHub Releases (notarized with a Homebrew cask once a paid Apple account or nonprofit waiver exists; otherwise un-notarized with install steps), Sparkle updates, Android APK on GitHub Releases and **F-Droid**.
  - Aim for reproducible Android builds, so F-Droid can ship the same developer-signed APK as GitHub and users can switch channels. Until then, document that the two channels can't update each other.
- Contributor docs: CONTRIBUTING, protocol spec, build-in-30-minutes README.
- **Decide the name/trademark question (PRD §12) before the public 1.0.**
- **Exit:** all PRD §10 success measures met.

## Version 1.x (after 1.0, as needed)
Fixes and polish from real users. Candidates:
- resumable transfers
- images on the shared clipboard
- notification history on the Mac
- Onboard the second contributor (CONTRIBUTING, good-first-issues)
- After the project becomes a nonprofit: Apple fee waiver → notarized builds; **Google Play** listing using the `play` flavor

## Version 2 (2.0)
- **F-20** Phone as Mac webcam (macOS Camera Extension + Android Camera2 stream).
- **F-21** Phone as Mac microphone.
- **F-22** One-click hotspot (Full mode on most phones).
- **F-23** *(Research)* Call audio through the Mac's mic and speakers.

## Versioning rules
- **App versions:** semantic versioning. The Mac app and Android app share the same version number for each release.
- **Protocol version:** a separate integer. It only increases on breaking changes; new features are added as **capabilities**, so mixed app versions keep working (Architecture §3.3).
- **Compatibility support:** each release talks to the previous minor release of the other app.
