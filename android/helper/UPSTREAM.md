# Vendored upstream: scrcpy-server

- **Project:** scrcpy, https://github.com/Genymobile/scrcpy (Apache License 2.0, see `LICENSE`, upstream's).
- **Tag:** `v5.0.1`
- **Commit:** `a60891aea193d92e7e5c3942700eca63f9d19a5f` (`git rev-parse v5.0.1^{commit}`, "Update links to 5.0.1", 2026-10-08)
- **Copied:** 2026-10-30, from a `git clone --depth 1 --branch v5.0.1` of the official repository.
- **What was copied:** `server/src/` unchanged into `src/` (the `com.genymobile.scrcpy` sources, the
  `android.content.IContentProvider` stub, the two AIDL files, `AndroidManifest.xml` and upstream's unit
  tests), and the repository's `LICENSE`. Upstream's `server/build.gradle` is translated into
  `build.gradle.kts`. Not copied: `build_without_gradle.sh`, `meson.build`, `scripts/`, `proguard-rules.pro`
  (minify is off) and the checkstyle config.
- **Version:** `versionName = "5.0.1-am1"`. `Server` refuses a client whose version argument differs, so the
  phone app launches it with `5.0.1-am1`.

## Build differences from upstream's release asset

The release asset `scrcpy-server-v5.0.1` (SHA-256 `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`)
is not byte-identical to our jar, and can't be: the version string, the two patches, our AGP and compileSdk all
differ, and upstream's asset was built at revision `dc8a55a2…` (its `version-control-info.textproto`), not the tag.
Two build choices on top of that:

- `kotlin-stdlib` is excluded. AGP 9's built-in Kotlin adds it to every module; upstream's asset carries it
  (2.3 MB `classes.dex`, 1,246 classes) although the server has no Kotlin code. Ours has 165 classes.
- `vcsInfo.include = false`, so the jar does not depend on the checkout's git state.

Comparing the two `classes.dex` files with `dexdump`, the `com.genymobile.scrcpy` and `android` classes and every
field and method signature are the same, apart from the patch classes below and two D8 API outlines for
`ClipDescription.getExtras()` and `PersistableBundle.getBoolean()` that P2 calls.

## Patches

Each patched upstream line ends with a `// anmirror P1` or `// anmirror P2` comment.

### P1: peer check on the local socket

Each connection accepted on `localabstract:scrcpy_<scid>` must come from uid 2000 (`shell`, which `adbd` runs as)
or uid 0. Any other peer is closed and the accept is repeated. The scid is only 31 random bits, so without this any
app on the phone could race the client's connect and receive the screen or inject input.

- New: `src/main/java/com/genymobile/scrcpy/anmirror/PeerCheck.java` (`isAllowed(int uid)` and `accept(LocalServerSocket)`).
- `src/main/java/com/genymobile/scrcpy/device/DesktopConnection.java`:
  - line 3: `import com.genymobile.scrcpy.anmirror.PeerCheck;`
  - lines 68, 76 and 84: `localServerSocket.accept()` becomes `PeerCheck.accept(localServerSocket)` for the video,
    audio and control sockets.

### P2: sensitive clips are not autosynced

With `clipboard_autosync=true`, a clip whose description has `android.content.extra.IS_SENSITIVE = true`
(`ClipDescription.EXTRA_IS_SENSITIVE`, Android 13; it is read on Android 7+, where the extras exist) is not sent to
the computer. If the description can't be read, the clip is not sent. An explicit GET_CLIPBOARD from the computer
is unchanged.

- New: `src/main/java/com/genymobile/scrcpy/anmirror/SensitiveClip.java` (`isPrimaryClipSensitive()`).
- `src/main/java/com/genymobile/scrcpy/control/Controller.java`, line 154 (in the clipboard listener, before
  `Device.getClipboardText()`): `if (com.genymobile.scrcpy.anmirror.SensitiveClip.isPrimaryClipSensitive()) return;`

## Our tests

- `src/test/java/com/genymobile/scrcpy/anmirror/PeerCheckTest.java`
- `src/test/java/com/genymobile/scrcpy/anmirror/ScrcpyFixturesTest.java`: checks `protocol/vectors/scrcpy.json`
  against the vendored `ControlMessageReader`, `DeviceMessageWriter`, `Streamer` and `DesktopConnection`.

## Updating

Copy the new tag's `server/src/` over `src/` (keeping `anmirror/`), re-apply P1 and P2 at the marked lines,
update this file, `versionName`, and `HELPER_VERSION` in `app/build.gradle.kts`.
