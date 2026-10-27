# Android Mirroring

**Your Android phone, part of your Mac.** An open-source pair of native apps (Swift on macOS, Kotlin on Android) that brings Continuity-style features to Android users on a Mac.

> **Status: design approved, building 0.1.** No code yet. The plan is in the docs below and is open for feedback.

## What it will do (version 1)

- 🔔 **Notifications on your Mac,** with actions and inline reply
- 📁 **Files both ways:** drag, Share menu, and your phone in Finder's sidebar
- 📋 **Shared clipboard** for text
- 📞 **Calls:** see, answer and decline from your Mac
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

## Requirements (planned)

- macOS 14 Sonoma or later
- Android 10 or later. Mirroring and control need Android 11+ and a one-time developer-mode step.

## License

Planned: Apache-2.0 (see [PRD §11](docs/PRD.md#11-decisions)).
