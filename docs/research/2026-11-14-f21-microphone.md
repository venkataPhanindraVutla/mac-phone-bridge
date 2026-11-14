# F-21 Phone as Mac microphone: research

Status: **Research** · Date: 2026-11-14 · Related: [PRD §7](../PRD.md#7-version-2-features-later) · [Architecture](../ARCHITECTURE.md) · [Roadmap](../ROADMAP.md) · [Protocol](../../protocol/SPEC.md)

**Goal:** the phone's mic shows up as an input device ("Phone Microphone") in Zoom, Meet, QuickTime and any other Mac app.

**Short answer:** this fits our constraints. A Core Audio **HAL plug-in** (an `.driver` bundle in `/Library/Audio/Plug-Ins/HAL`) is not a system extension, needs no entitlement and no paid account, and the Android side mostly exists already in the vendored scrcpy helper. One thing is not proven: that `coreaudiod` loads our **ad-hoc signed, un-notarized** driver on another person's Mac. That needs a one-day spike before we commit.

Legend: ✅ checked against a primary source · ⚠️ partly checked or depends on the device · ❓ not verified

---

## 1. Mac side: how to show a virtual input device

### Options

| Option | Paid account? | Installs with free Apple ID, ad-hoc, no notarization? | Notes |
|---|---|---|---|
| **A. AudioServerPlugIn (HAL plug-in)** | No | ⚠️ Very likely (see §2) | What BlackHole, Zoom's own audio device, Krisp, Loopback etc. use. Proven pattern. |
| B. AudioDriverKit (DriverKit system extension) | **Yes** | ✅ No | Needs `com.apple.developer.driverkit` entitlements from Apple. Apple's own sample says ad-hoc testing requires **disabling SIP**. [1] Ruled out. |
| C. Core Audio tap in a public aggregate device (macOS 14.2+) | No | ❓ Unknown | Our app plays the phone audio into a muted tap; a public aggregate device with that tap as its input is what Zoom selects. No driver to install. But the "System audio recording" permission prompt may land on **Zoom**, not us, and other apps may not see it cleanly. [2] Worth a half-day test, not the plan. |
| D. Kernel extension, DAL plug-in | — | ✅ No | Kexts are deprecated and need SIP/approval changes; DAL is video-only and dead since macOS 14.1. |

**Pick A.** It is the only option that is both proven and free.

### What a HAL plug-in is (✅ from Apple's header)

From `CoreAudio/AudioServerPlugIn.h` (macOS SDK) [3]:
- A CFPlugIn bundle named `*.driver`, installed in `/Library/Audio/Plug-Ins/HAL`.
- It runs **in its own sandboxed process**, not inside our app. It may only read its own bundle.
- To talk to another process it must list the Mach service names in `AudioServerPlugIn_MachServices` in its Info.plist; network use needs `AudioServerPlugIn_Network = true`.

Apple's minimal sample, "Creating an Audio Server Driver Plug-in" (NullAudio, plain C), says: install the `.driver` to `/Library/Audio/Plug-Ins/HAL` and reboot. [4]

### Proposed design: two devices in one plug-in, no IPC

The simplest proven trick (BlackHole's) is a **loopback**: audio played into the device's output comes back out of its input. That avoids Mach services, LaunchAgents and shared memory, which are all hard without a paid account.

To stop users from picking it as a speaker by mistake:
- **"Phone Microphone"**: visible, **input only**.
- **"Phone Microphone (feed)"**: **hidden**, output only. Both share one ring buffer inside the plug-in process.
- A hidden device is left out of every device list and can't be the default, but can be found **by its UID** (`kAudioDevicePropertyIsHidden`, `AudioHardwareBase.h`) ✅ [3]. Our app opens it by UID and plays the decoded phone audio into it with `AVAudioEngine`, which the mirror feature already uses.

Code to start from (licence matters, we're Apache-2.0):
- Apple's NullAudio sample (Apple sample-code licence, permissive) [4], or
- **libASPL**, a C++17 library for AudioServerPlugIns, **MIT** ✅ [5].
- **Do not copy BlackHole**: it is **GPL-3.0** ✅ [6]. We can learn from how it works, but we can't copy its code (same rule as KDE Connect, Architecture §10).

The driver must be **universal** (arm64 + x86_64), because we support Intel Macs (PRD §9).

## 2. Does it load with a free Apple ID, ad-hoc signing and no notarization?

This is the hard constraint, so here is exactly what is and isn't known.

- ✅ A HAL plug-in is **not** a system extension. It needs no entitlement and no provisioning profile, so a free Apple ID can build and sign it. Apple's sample only says "install and reboot". [4]
- ✅ BlackHole's README tells people who build it themselves just to copy the built bundle into the HAL folder and restart Core Audio. There is no Developer ID step. Its *released* installer is signed and notarized. [6]
- ⚠️ Open-source reports disagree. One project says `coreaudiod` loads ad-hoc plug-ins on a normal SIP-on Mac. Another says only Developer ID works. A third says the real problem is **quarantine**: a quarantined ad-hoc bundle is refused, and their installer strips `com.apple.quarantine` before copying. Another notes that the Core Audio driver host carries `disable-library-validation` and no hardened runtime, which makes ad-hoc loading plausible. [7] None of these are Apple documents.
- ❓ **Not verified on macOS 14, 15 or 26:** whether an ad-hoc driver copied out of our quarantined DMG loads after we remove the quarantine flag.

**What this means:** most likely it works if our installer removes the quarantine flag from the driver bundle it copies. That is a per-file flag on our own files, not a system security setting, and it does not touch SIP or Gatekeeper settings. **Spike first (1 day):** build the NullAudio sample ad-hoc, put it in a DMG, download it on a second Mac, install, restart Core Audio, and check that QuickTime lists it. Do this on macOS 14 and 26, on Apple silicon and Intel.

If the spike fails, F-21 waits for the paid account or nonprofit fee waiver, the same as F-20.

## 3. Install and uninstall

Copying into `/Library` needs an admin password. Without Developer ID we can't use `SMJobBless`, so:

**Install (from the app, one click):**
1. The app runs one privileged shell command through the standard macOS admin prompt (`NSAppleScript` "do shell script … with administrator privileges"). The command:
   - copies `PhoneMic.driver` from inside the app bundle to `/Library/Audio/Plug-Ins/HAL/`
   - removes the quarantine flag from that copy (`xattr -dr com.apple.quarantine …`)
   - restarts Core Audio (`killall coreaudiod`; BlackHole uses `sudo killall -9 coreaudiod` [6]). This cuts all Mac audio for about a second, so the app says so first.
2. The app checks that a device with our UID now exists, and shows "Phone Microphone is ready".

**Fallback:** the same three commands in the setup guide for Terminal, the way the guide already handles "Open Anyway".

**Uninstall:** a button in Settings removes the bundle and restarts Core Audio. Because a driver is not tied to the app (unlike system extensions), deleting the app does **not** remove it. The guide must say so, and the DMG should include an "Uninstall Phone Microphone" command.

**Updates:** Sparkle updates the app, not the driver. The app compares the installed driver's version with its bundled copy and offers to update it, which means one more password prompt.

## 4. Android side: capturing the mic

### Full mode (Android 11+): almost free

The vendored scrcpy v5.0.1 helper already captures the mic. `AudioSource.java` maps `mic`, `mic-unprocessed`, `mic-voice-communication` and others to `MediaRecorder.AudioSource` values ✅ (`android/helper/.../audio/AudioSource.java`). scrcpy documents `--audio-source=mic --no-video` for exactly this kind of use ✅ [8]. The helper runs as the shell user, which holds `RECORD_AUDIO` in AOSP ✅ [9].

What is needed:
- `MirrorStart` (or a new `mic.start`) passes `audio_source` and a `video=false` option. Today the spec only passes `max_size`, `video_bit_rate`, `max_fps`, `video_codec`, `audio`, `audio_codec` (SPEC §24).
- Default to `mic-voice-communication`: the phone's own echo cancellation and noise suppression ✅ [8].
- Android 11 needs the screen unlocked to start audio capture (scrcpy's HeapDumpActivity workaround). Android 12+ works out of the box ✅ [8].

### Basic mode (no developer mode): possible, with one phone tap

The companion app can record with `AudioRecord` itself. The rules:
- `RECORD_AUDIO` is a runtime permission, asked when the user turns F-21 on.
- The foreground service needs type **`microphone`** and `FOREGROUND_SERVICE_MICROPHONE` (a normal permission ✅ [10]). We already hold `connectedDevice`.
- ✅ **While-in-use rule (Android 14+):** a mic foreground service started while the app is in the background throws `SecurityException` (on older versions it starts but gets no audio). Exemptions include "the service starts by interacting with a **notification**" and "with app widgets" [11]. **So a click on the Mac can't start the phone mic by itself.** The Mac asks, the phone shows a "Use as Mac microphone? Start" notification, and one tap on it starts capture. A Quick Settings tile also counts as user interaction.
- Encode with the platform Opus encoder through `MediaCodec` (Android 10+), the same as the helper.

### Things the user will notice (✅ Android's audio-sharing rules [12])
- **During a phone or WhatsApp call on the phone, the call always gets the mic.** Our capture gets silence. The Mac should show "Phone mic is busy (call on phone)".
- If another app on the phone records with its UI on top, it can win the mic. Using the `VOICE_COMMUNICATION` source ("privacy-sensitive") raises our priority.
- Android 12+ shows the green mic dot while we record. That is correct and wanted.

## 5. Codec and transport over the existing link

- **Codec: Opus, 48 kHz.** The helper already encodes it, and the Mac already decodes it with `AudioConverter` (`FeatureMirror/AudioDecoder.swift`). Mono at 32–64 kbit/s is enough for speech. The helper hard-codes stereo today (`AudioConfig.java`), so stereo at about 64 kbit/s is fine as a first step.
- **Transport:** reuse the bulk-connection role `MIRROR_AUDIO` (SPEC §13), or add a role `MIC_AUDIO` with its own token, so the mic can run **without** a mirror session. It's TLS over TCP, the same as mirroring. TCP can stall for a moment on Wi-Fi loss, so the Mac must **drop old audio** instead of letting delay grow. (The phone already ends a session at more than 512 KiB of queued audio, SPEC §24.)
- **Capability:** `mic.v1` in the handshake (Architecture §3.3), with `mic.availability` / `mic.start` / `mic.stop` / `mic.state` on a new `MIC` channel, shaped like `mirror.*`.
- **Clock drift:** the phone's 48 kHz clock and the Mac's never match exactly. Over a 1-hour call a 0.01% difference is 360 ms. The Mac feeder must keep its buffer level steady by resampling slightly (or dropping and repeating single samples at silent points). This is the one piece of new DSP work.

## 6. Latency budget (one way, phone mouth → Mac app)

| Step | Estimate | Source |
|---|---|---|
| `AudioRecord` block (1024 samples at 48 kHz) | ~21 ms | ✅ helper `AudioConfig.MAX_READ_SIZE` comment |
| Opus frame | 20 ms | ⚠️ typical Android encoder framing |
| Wi-Fi + TLS | 5–20 ms | ❓ to measure on reference phones |
| Mac jitter buffer | 40–60 ms | ✅ scrcpy defaults to a 50 ms audio buffer [8] |
| HAL device I/O buffer | ~10 ms | ⚠️ 512 frames at 48 kHz |
| **Total** | **~100–130 ms** | |

That is within the usual guidance for conversation, under 150 ms one way (ITU-T G.114) ❓ (standard not re-checked for this report). **Target: under 150 ms on reference phones over 5 GHz Wi-Fi**, measured with the latency harness in `/scripts`.

Lip sync: if the user also uses F-20 (phone camera), both streams come from the phone with similar delay, which is good. With the Mac's own camera, audio will trail video by about 100 ms. Video-call apps usually tolerate audio arriving a little late better than early.

## 7. Battery

❓ Not measured. Mic capture, Opus encoding and keeping Wi-Fi active for a 1-hour call will plausibly cost a few percent per hour on a modern phone, similar to a VoIP call. It only runs while in use, so it doesn't affect the "under 4%/day idle" target (PRD §4). **Measure** during the spike with Android's battery stats.

## 8. Recommendation

**Build, after a one-day signing spike.**

- **Rough size:** about 3–5 weeks for owner + Claude.
  - Mac driver: C/C++ via libASPL, two devices and a ring buffer, about 1.5k lines.
  - Installer, uninstaller and version check.
  - Feeder with drift correction.
  - `mic.v1` protocol and conformance vectors.
  - Android: Full mode is an option change in the helper launch; Basic mode is a mic foreground service plus a notification.
- **Order:** spike (ad-hoc driver loads from a downloaded DMG) → Full-mode mic (reuses the helper) → Basic-mode mic.

**What the user must decide:**
1. Is a **one-time admin password plus a ~1 s audio blip** at install acceptable for an un-notarized app? (No other free path exists.)
2. **Basic mode too, or Full mode only at first?** Basic needs a tap on the phone to start each time (Android rule); Full can start from the Mac.
3. If the spike shows ad-hoc drivers **don't** load: wait for the fee waiver, or try option C (aggregate device, macOS 14.2+ only, with an odd permission prompt)?

## Sources

1. Apple, "Building an Audio Server Plug-in and Driver Extension" (ad-hoc testing requires disabling SIP): https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension
2. Apple, "Capturing system audio with Core Audio taps" (tap as input of an aggregate device; macOS 14.2+; permission prompt on first recording): https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
3. macOS SDK headers `CoreAudio/AudioServerPlugIn.h` (location, sandbox, `AudioServerPlugIn_MachServices`) and `CoreAudio/AudioHardwareBase.h` (`kAudioDevicePropertyIsHidden`). Read from the Xcode SDK on 2026-11-14.
4. Apple, "Creating an Audio Server Driver Plug-in" (NullAudio sample): https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
5. libASPL (MIT): https://github.com/gavv/libASPL
6. BlackHole README (build and install, `killall -9 coreaudiod`, uninstall, GPL-3.0): https://github.com/ExistentialAudio/BlackHole
7. Community reports on ad-hoc HAL plug-ins (not Apple sources): https://github.com/wannabemrrobot/frEQ, https://github.com/trsdn/OpenConnct, https://github.com/ReCire/rk3-coreaudio, https://github.com/madduck-tech/backchannel/issues/316
8. scrcpy v5.0.1 `doc/audio.md` (sources, Android 11/12 behaviour, 50 ms buffer): https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/audio.md
9. AOSP Shell manifest (`RECORD_AUDIO`): https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/packages/Shell/AndroidManifest.xml
10. AOSP core manifest (`FOREGROUND_SERVICE_MICROPHONE`, normal): https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/core/res/AndroidManifest.xml
11. Android, "Restrictions on starting a foreground service from the background" (while-in-use exemptions): https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
12. Android, "Sharing audio input": https://developer.android.com/media/platform/sharing-audio-input
