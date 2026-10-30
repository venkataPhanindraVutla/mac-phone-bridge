# Milestone 0.1 Patch: Screen-off Keep-alive Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A paired phone that is unplugged, locked and untouched for 30 minutes or more stays connected to the Mac and rings when the Mac asks. This is 0.1 check (h), which failed on the owner's vivo V2558.

**Architecture:**
- **Diagnosis from the code.** The phone's timers are coroutine `delay`s, and they run on `CLOCK_MONOTONIC`, which stops while the CPU is suspended. So a screen-off phone never sends its 30 s ping. The Mac drops it after 75 s of silence. The FIN wakes the phone, which reconnects at once and goes back to sleep. That is the "new TCP session every 1.5–2 min" in the owner's log.
  - The longer gaps came after a failed dial. The phone then waits out a backoff of up to 60 s, and that delay is frozen too.
  - The final loss came when the foreground service went away while the process lived on. Without the service, the process is frozen (`fast_freezer`) and has no network.
  - `MainActivity.onResume` gates the restart on a static `running` flag. The flag is only cleared in `onDestroy`, so it goes stale if `onDestroy` never runs. Separately, a transient Keystore failure reads the store as "no Mac paired", and the service then stops itself.
- **Mac-driven liveness (new capability `liveness.v1`).**
  - The Mac pings every 30 s, and the phone answers at once. An incoming packet wakes the phone, so the phone never needs its own timer to fire.
  - The Mac drops a phone after 3 intervals in a row with nothing received, so between 90 and 120 s after the phone's last message.
  - The phone pings on its own only after 45 s of awake quiet, as a fallback.
  - Peers without the capability keep the 0.1 rules exactly.
  - TCP keepalive (idle 60 s, interval 10 s, 3 probes) is on for control and bulk sockets on both ends.
- **Service survival.**
  - Opening the app always (re)starts the service when a Mac is paired.
  - The service stops itself only when the store is confirmed empty, never when it is unreadable.
  - An `AlarmManager` watchdog restarts the service, or kicks the manager, every 15 min.
  - Screen-on and network changes kick the manager at once, and the reconnect backoff is capped at 30 s.
  - A content-free event log on the phone records every step, so the next failure can be diagnosed.
- **Battery exemption in setup.**
  - After pairing, the app asks for `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and shows a maker-specific step.
  - A home row stays until the phone is exempt.
  - `StatusUpdate.background_restricted` lets the Mac menu say "Phone may disconnect when locked".

**Tech Stack:** as 0.1–0.4 (Swift 6, Network.framework, swift-protobuf, Swift Testing; Kotlin, coroutines, protobuf-lite, Compose, kotlin.test). New APIs:
- **Android:** `AlarmManager.setAndAllowWhileIdle(ELAPSED_REALTIME_WAKEUP)`, `PowerManager.isIgnoringBatteryOptimizations`, `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `ActivityManager.getRunningServices` (own services only), `ActivityManager.getHistoricalProcessExitReasons` (API 30+), `ParcelFileDescriptor.fromSocket` with `android.system.Os.setsockoptInt`.
- **JVM (phone-sim):** `jdk.net.ExtendedSocketOptions`.
- **Mac:** `NWProtocolTCP.Options.enableKeepalive` / `keepaliveIdle` / `keepaliveInterval` / `keepaliveCount`.

No new third-party dependencies (no WorkManager, no Google Play services).

**Spec:**
- [docs/milestones/0.1-results.md](../../milestones/0.1-results.md), check (h): "If this fails, 0.1 is not done: the keep-alive model needs a redesign (Mac-driven pings plus TCP keepalive, so an idle phone need not wake to send)".
- [protocol/SPEC.md](../../../protocol/SPEC.md) §1, §3, §7 and §13.
- [docs/ARCHITECTURE.md](../../ARCHITECTURE.md) §3.3 and §5.
- [docs/PRD.md](../../PRD.md) F-02, §8 (Battery, Reliability) and §13 (first risk).
- The 0.1 SDD ledger rulings: R16 (backoff), R17/R19 (backoff reset after a session that lived one ping interval), R38 (the 75 s detection, builder's call) and R39 (this check, and the redesign if it fails).
- The controller's design direction of 2026-10-30, summarised under "Design direction" below.

This plan builds on branch `milestone-0.1` at `8cc13a5` (0.1–0.4 complete) and is executed on `fix/keepalive`.

**Evidence the plan argues from** (owner's phone: vivo V2558, OriginOS 6, Android 16; Mac on the same Wi-Fi):
- **First run, 32 min.** The phone was unplugged, screen off, untouched.
  - The Mac logged a new TCP session every 1.5–2 min.
  - It dropped 15:53–15:54, 15:56–16:03 and 16:15–16:23.
  - At 16:38 there was no session at all, and Ring did nothing.
- **At 16:45:**
  - `ConnectionService` (FGS, type `connectedDevice`) was not running; only the NotificationListenerService was.
  - The process kept the same pid it had since 15:06.
  - Opening `MainActivity` did not restart the service. Re-pairing did.
- **16:40–16:48:** `am_app_frozen ... from fast_freezer` / `am_app_unfrozen` cycles, while no FGS was running.
- **With the FGS running (16:50):** procState 4 (fg-service), `isShouldNotFreeze=true`, not frozen.
- **Network:** network policy blocks the app in the background unless it is FOREGROUND/TOP or not in the background, so the network depends on the FGS.
- **Exemptions:** not on the deviceidle whitelist, and vivo "Background power consumption management" was not set to Allow.
- **Second run:** a 30-minute run with the exemption ON and a phone-side event log is in progress. Task 1 Step 1 records it, and the plan holds either way (see Task 1).

**Design direction (controller), and where this plan departs from it:**
1. **Mac-driven liveness:** followed. The values chosen:
   - **Count and window.** Ping every 30 s, and drop after **3** silent intervals, so 90–120 s after the last message.
     - Doze can't set the count. The gaps between Doze maintenance windows are minutes in light Doze and 1–6 h in deep Doze, and no count can bridge those. A window that long would let the menu say Connected for hours while Ring silently fails.
     - The design instead keeps the phone's network up: the FGS's procState is exempt from Doze's network block, and the phone is battery-exempt. The count only has to absorb radio gaps measured in seconds: Wi-Fi power-save wake latency, TCP retransmission, an AP roam or a 60 s DFS channel check.
     - 3 intervals tolerate any gap under 60 s.
   - **User-visible change.** "Disconnected when the phone vanishes" moves from "within 75 s" to "within 2 minutes" for `liveness.v1` phones. PRD F-02 and SPEC §7 are updated (R38 was a builder's call).
2. **TCP keepalive:** followed, but as defence in depth only.
   - A frozen app's kernel still ACKs keepalive probes, so keepalive can't see a frozen app. A suspended phone runs no kernel timers either.
   - The app-level ping is what detects both. Keepalive helps on idle bulk sockets and with legacy peers.
3. **Compatibility:** a capability, `liveness.v1`.
   - Our 0.1–0.4 phones already answer a Mac ping (`PhoneSession` replies `system.pong`). But SPEC §3 lists `system.ping` as phone-to-Mac only, so a conforming third-party phone need not answer one.
   - The Mac pings, and drops on missed pings, only when the capability is shared. Otherwise it keeps the 75 s silence rule.
4. **Watchdog:** `AlarmManager`, not WorkManager.
   - WorkManager would be the project's first new dependency. Its periodic minimum is the same 15 min.
   - Neither may start an FGS from the background unless the app is battery-exempt, so the watchdog does not change that.
   - The repo already uses inexact `setAndAllowWhileIdle` alarms (`feature/proximity/WakeAlarm.kt`).
   - When the start is refused, the watchdog posts a "Tap to reconnect" notification instead.
5. **Backoff cap: 30 s** (was 60 s, ruling R16).
   - R16's 60 s cap protected the battery. But backoff waits are frozen in suspend, so a long cap only delays reconnects while the phone is awake.
   - The first ~22 s of R16 (1, 2, 4, 5, 5, 5 s) stay; then 15 s once, then 30 s.
6. **Two extra service-survival fixes from the code,** beyond the stale flag:
   - The service stops itself only when the store is confirmed empty. A transient Keystore failure otherwise reads as "no Mac".
   - The manager re-reads an unreadable store every 30 s instead of waiting for a kick.

Build rulings for this patch are numbered **K1, K2, …** (the 0.1 ledger ends at R39 and 0.5 reuses R-numbers).

## Global Constraints

Everything in the 0.1–0.4 plans' Global Constraints still applies. The 0.2–0.4 rule "do not change ConnectionManager / PhoneSession / MacServer / ControlConnection logic" is **lifted for this patch only**: those files are what it fixes.

**Hard rules carried from 0.1–0.4**
- **License:** Apache-2.0. No GPL code.
- **Never read SMS.**
- **No content in logs.** Log only event codes, class names, enum names, booleans, counts, ids and durations. No Mac names, hosts, addresses, fingerprints or discovery keys. The phone's event-log `detail` field is sanitised to `[A-Za-z0-9_=.,-]` (Task 1).
- **Permissions only when a feature needs them.** `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is a normal permission. Its dialog is opened only from the post-pairing screen and the home row, never at launch.
- **Swift 6:** no `@MainActor`-isolated closure handed to a system API. Build those in nonisolated helpers. Timers use `Task.sleep` inside `MacServer`'s own tasks, not `Timer` or `DispatchSourceTimer` with a MainActor closure.
- **The Android app works without Google Play services** (it ships on F-Droid). No WorkManager, no Play APIs.
- **Free Apple ID only.** No entitlement or capability that needs a paid account.
- **SPEC §3:** no feature message unless the peer lists the capability. A Mac ping goes to a phone only when `liveness.v1` is shared.
- **Copy written by implementers** is listed for owner review in the results doc.

**Protocol values (exact)**
- **Capability:** `liveness.v1`. Swift `Liveness.capability`, Kotlin `LIVENESS_CAPABILITY`.
- **With `liveness.v1` shared:**
  - **The Mac:**
    - sends `system.ping` (channel SYSTEM, empty `Ping`) every **30 s**, the first 30 s after the hello;
    - counts any incoming envelope as proof of life;
    - drops the phone when **3** consecutive intervals pass with nothing received;
    - does not apply the 75 s silence rule to that session.
  - **The phone:**
    - answers each `system.ping` at once with `system.pong`, `reply_to` = the ping's id;
    - sends its own ping only after **45 s** with nothing received, measured on monotonic uptime (stops in deep sleep);
    - drops if nothing arrives within **10 s** of that ping.
- **Without it:** SPEC §7 as in 0.1. The phone pings every 30 s, a pong must arrive within 10 s, and the Mac drops after 75 s of silence.
- **TCP keepalive:** idle **60 s**, interval **10 s**, **3** probes, on the control and bulk sockets of both apps and both sims.
  - Linux option numbers: `TCP_KEEPIDLE = 4`, `TCP_KEEPINTVL = 5`, `TCP_KEEPCNT = 6`.
- **`StatusUpdate.background_restricted`** (field 5, bool): `true` when the phone is not exempt from battery optimisation. Older phones leave it `false`.
- **Phone backoff:** 1, 2, 4, 5, 5, 5 s, then 15 s once, then 30 s each time. Busy stays 60 s, NotRecognized 15 min, and the pong timeout 10 s.
- **Watchdog:** an inexact `setAndAllowWhileIdle(ELAPSED_REALTIME_WAKEUP, now + 15 min)`, re-armed on every fire.
- **Unreadable store re-read:** 30 s.
- **Event log:** `filesDir/keepalive-events.log`, keeping the newest **500** lines.

**Copy (exact)**
- **Mac menu:** `"Phone may disconnect when locked"`, under the status line while connected and `background_restricted` is true.
- **Phone, post-pairing screen and home row** (`strings.xml`):
  - `keep_title` = "Stay connected when the phone is locked"
  - `keep_body` = "To save battery, Android may stop Android Mirroring while the screen is off. Your Mac then can't ring the phone or show its notifications."
  - `keep_allow` = "Allow in the background"
  - `keep_maker_intro` = "On this phone, also turn this on:"
  - `keep_open_settings` = "Open app settings"
  - `keep_done` = "Done"
  - `keep_not_now` = "Not now"
  - `keep_row_title` = "May disconnect when locked"
  - `keep_row_line` = "Allow Android Mirroring to run in the background."
  - `keep_row_fix` = "Fix"
- **Maker lines:**
  - `keep_maker_vivo` = "Settings › Battery › Background power consumption management › Android Mirroring › Allow"
  - `keep_maker_xiaomi` = "Settings › Apps › Manage apps › Android Mirroring › Autostart on, and Battery saver › No restrictions"
  - `keep_maker_oppo` = "Settings › Apps › App management › Android Mirroring › Battery usage › Allow background activity"
  - `keep_maker_samsung` = "Settings › Battery › Background usage limits › Never sleeping apps › add Android Mirroring"
  - `keep_maker_huawei` = "Settings › Battery › App launch › Android Mirroring › Manage manually, with Run in background on"
  - Only the vivo line has been seen on a real phone. The others go on the owner's copy-review list.
- **Reconnect notification** (channel `connection`):
  - `reconnect_title` = "Android Mirroring stopped"
  - `reconnect_text` = "Tap to reconnect to your Mac."

**Google Play (for later, not this patch):** `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is a restricted permission under Play policy. The future `play` flavor (ARCHITECTURE §5) should drop it and open `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` instead, or justify it to Google. Record this in the results doc. F-Droid accepts the permission.

## Review Focus

These are the five failures a person is most likely to hit that no feature test covers. Each one gets its tests in the task named in brackets.

1. **A frozen phone app with its socket still open** (vivo `fast_freezer`, or the process stopped). The kernel still ACKs TCP and keepalive probes, but nothing answers pings. Expected:
   - The Mac drops it within 120 s and shows Not connected.
   - TCP does not fool it.

   *(Task 3 `silentLivenessPhoneIsDroppedAfterThreeMissedIntervals`, `livenessSessionIgnoresSilenceTimeout`; Task 4 interop case 11, which runs `kill -STOP` on phone-sim)*
2. **Mixed versions.** A new Mac with a 0.1–0.4 phone, an old Mac with a new phone, or a third-party phone that never answers Mac pings. Expected:
   - No Mac pings unless `liveness.v1` is shared.
   - The 0.1 rules hold for those sessions, unchanged.

   *(Task 3 `legacyPhoneGetsNoPings`; Task 4 `legacyModeIgnoresNonPongTraffic`, the unchanged `reconnectsWhenPongMissing` and `keepsConnectionWhilePongsArrive`, interop case 12)*
3. **A store read that fails for a moment** (Keystore busy or reset while locked). Expected:
   - The service keeps running.
   - The manager retries within 30 s.
   - The pairings are not dropped.

   *(Task 1 `providerExceptionIsUnreadable`, `unreadableStoreNeverStopsService`, `absentFileIsConfirmedEmpty`)*
4. **The service is gone but the process lives** (stale `running` flag, an OEM stop, the user opening the app later). Expected:
   - Opening the app always restarts it.
   - The watchdog restarts it within ~15 min when exempt, and otherwise posts "Tap to reconnect".
   - Nothing restarts once no Mac is paired.

   *(Task 1 `appOpenStartsServiceWheneverPaired`; Task 5 `pairedAndNotRunningStartsService`, `runningButNotConnectedKicks`, `nothingPairedCancels`, `unreadableStoreCountsAsPaired`)*
5. **A burst of wake-ups** (screen-on, a network change and the watchdog at once, after a long sleep with a dead connection). Expected:
   - One dial, not three.
   - A connected session sends one immediate ping and drops 10 s later if it is dead.
   - The backoff never drops below 1 s or rises above 30 s.

   *(Task 4 `burstOfKicksDialsOnce`, `kickPingsAtOnceInMacDrivenMode`, `backoffCapsAt30sAfterSixAttempts`)*

---

## File Map

```
protocol/
  proto/anmirror/v1/status.proto                                     modified (background_restricted = 5)
  SPEC.md                                                            modified (§1, §3 ping row + capability, §7, §13)
  tools/make_vectors.py, vectors/framing.json                        modified (ping_from_mac, status_update_background_restricted)
docs/
  PRD.md (F-02), ARCHITECTURE.md (§3.3, §5)                          modified
  milestones/0.1-keepalive-results.md                                new (Task 1 evidence, Task 7 the rest)
  milestones/0.1-results.md                                          modified (check (h) result + pointer)
scripts/interop-test.sh                                              modified (cases 10–12; SIGCONT before kill)
mac/Packages/AMKit/
  Sources/ConnectionCore/Liveness.swift                              new (Liveness.capability, LivenessMonitor)
  Sources/ConnectionCore/MacServer.swift, TLSParameters.swift        modified
  Sources/FeatureStatus/{PhoneStatusModel,StatusFormatter}.swift     modified
  Sources/am-mac-sim/main.swift                                      modified (--liveness, --ping-interval-ms)
  Tests/ConnectionCoreTests/{LivenessMonitorTests,MacServerLivenessTests,TLSParametersTests}.swift  new
  Tests/ConnectionCoreTests/MacServerTests.swift                     modified (startServer params)
  Tests/FeatureStatusTests/StatusFormatterTests.swift                modified
mac/App/AppModel.swift, MenuContent.swift, Localizable.xcstrings     modified
android/
  core/connection/.../{Liveness,SocketTuner}.kt                      new
  core/connection/.../{PhoneSession,ConnectionManager,TlsConnector}.kt   modified
  core/connection/src/test/.../{PhoneLivenessTest,PhoneSessionLivenessTest}.kt  new; ConnectionManagerTest, Fakes, TlsConnectorTest modified
  feature/status/.../PhoneStatus.kt (+ test)                         modified
  tools/phone-sim/.../{Main.kt, JdkKeepAliveTuner.kt}                modified / new (--liveness)
  app/src/main/
    AndroidManifest.xml                                              modified (permission, receiver)
    kotlin/.../diag/KeepAliveLog.kt                                  new
    kotlin/.../platform/{PairedMacsBlob,AndroidKeepAliveTuner,Battery}.kt   new
    kotlin/.../platform/EncryptedPairedMacStore.kt                   modified
    kotlin/.../service/{ServiceProbe,KeepAliveWatchdog,KeepAliveWatchdogReceiver,ScreenOnKicker,ReconnectNotice}.kt  new
    kotlin/.../service/{ConnectionService,BootReceiver}.kt           modified
    kotlin/.../{MakerGuidance,AppGraph,MainActivity}.kt              new / modified
    kotlin/.../ui/{KeepConnectedScreen,HomeScreen}.kt                new / modified
    res/values/strings.xml                                           modified
  app/src/test/.../{KeepAliveLogTest,PairedMacsBlobTest,WatchdogDecisionTest,MakerGuidanceTest,BackgroundStateTest}.kt  new; BootDecisionTest modified
README.md                                                            modified (one setup line)
```

---

## Order and parallelism

- **Task 1** (Android app: survival fix and event log) and **Task 2** (protocol and docs) share no files. **They run in parallel.**
- **After Task 2, two lanes:**
  - **Mac lane:** Task 3.
  - **Android lane:** Task 4. It touches only `core/connection`, `feature/status` and `phone-sim`, so it can also run alongside Task 1.
  - **3 ∥ 4** in separate worktrees. The one cross-lane link is Task 4's last step (interop cases 10–12), which needs Task 3's `am-mac-sim --liveness` merged first.
- **Android app lane, after 1 and 4:** Task 5 → Task 6. Both modify `AppGraph.kt`, `ConnectionService.kt`, `strings.xml` and the manifest, so they run in order.
- **Task 7** (owner checks and results) comes last.
- **Merge note for `milestone-0.5`:** so far 0.5 changes only `SPEC.md` (new sections) and protos other than `status.proto`. After merging, re-run `scripts/gen-proto.sh` and `make_vectors.py`; `framing.json` will need regenerating, not hand-merging.

---

### Task 1: Phone service survival: diagnose, restart on open, never stop on an unreadable store

*Platform: Android app. Depends on: nothing. Parallel: with Task 2 and Task 4.*

This task ships the same fixes whatever the second run shows. Step 1 records which cause the evidence supports, so the results doc can say which fix closed it.

**Files:**
- Create:
  - `android/app/src/main/kotlin/io/github/anmirror/phone/diag/KeepAliveLog.kt`
  - `.../phone/platform/PairedMacsBlob.kt`
  - `.../phone/service/ServiceProbe.kt`
  - `docs/milestones/0.1-keepalive-results.md` (the "Evidence" section only)
- Modify:
  - `.../platform/EncryptedPairedMacStore.kt`
  - `.../service/BootReceiver.kt` (`BootDecision`)
  - `.../service/ConnectionService.kt` (`onCreate`, `onStartCommand`, `onDestroy`, `onState`)
  - `.../MainActivity.kt` (`onResume`)
  - `.../AppGraph.kt` (wiring, process-start record)
- Test:
  - `android/app/src/test/kotlin/io/github/anmirror/phone/KeepAliveLogTest.kt`
  - `PairedMacsBlobTest.kt`
  - `BootDecisionTest.kt`

**Interfaces:**
- Produces:

```kotlin
// diag/KeepAliveLog.kt
enum class KeepAliveEvent(val code: String) {
    PROCESS_START("process-start"), APP_OPEN("app-open"),
    SERVICE_CREATE("service-create"), SERVICE_START("service-start"), SERVICE_DESTROY("service-destroy"),
    SERVICE_SELF_STOP("service-self-stop"), STATE("state"), STORE_UNREADABLE("store-unreadable"),
    SCREEN_ON("screen-on"), NETWORK("network"), WATCHDOG("watchdog"), EXEMPT("exempt"),
}
class KeepAliveLog(file: File, maxLines: Int = 500, clock: () -> Long = System::currentTimeMillis) {
    fun record(event: KeepAliveEvent, detail: String = "")   // thread-safe; never throws
}
// platform/PairedMacsBlob.kt
sealed interface StoreRead {
    data class Macs(val macs: List<PairedMac>) : StoreRead
    data class Unreadable(val causeClass: String) : StoreRead
}
object PairedMacsBlob { fun decode(blob: ByteArray?, decrypt: (ByteArray) -> ByteArray): StoreRead }  // null blob = file absent
// EncryptedPairedMacStore(file, cipher, onUnreadable: (causeClass: String) -> Unit = {})   // AppGraph passes keepAliveLog STORE_UNREADABLE
suspend fun confirmedEmpty(): Boolean          // true only for StoreRead.Macs(emptyList())
// BootDecision
fun shouldSelfStop(pairingUnderWay: Boolean, confirmedEmpty: Boolean): Boolean
// service/ServiceProbe.kt
object ServiceProbe { fun connectionServiceRunning(context: Context): Boolean }  // AMS view: own service, foreground
// AppGraph
val keepAliveLog: KeepAliveLog
suspend fun noMacPaired(): Boolean             // = encrypted store's confirmedEmpty()
```

- [ ] **Step 1: Record the evidence.** Create `docs/milestones/0.1-keepalive-results.md` with a section "Evidence".
  - Copy in the first-run facts from this plan's header.
  - Add the second run (exemption ON), as the controller reports it: minutes, drops, whether Ring worked, and the phone-side log.
  - Then fill a table with one row per cause: "supported / refuted / no data".
    - **H1, stale `running` flag:** the service record is gone and `onDestroy` never ran.
    - **H2, unreadable store:** it read as "no Mac", and the service stopped itself.
    - **H3, the system or OEM stopped the service:** `onDestroy` ran, with no self-stop.
    - **H4, the process was killed** and its sticky restart deferred. The same pid in run 1 refutes it there.
  - **If the second run passed** (the exemption alone was enough):
    - Still ship every step below. Run 1 shows the flag and the self-stop paths are reachable without an exemption.
    - Tasks 3 and 4 remove the 75 s churn either way.
  - **If it failed with a cause outside H1–H4:** finish this task, then report BLOCKED with the evidence before Task 5.
- [ ] **Step 2: Write the failing tests.**
  - `KeepAliveLogTest`:
    - `lineIsUtcTimeCodeAndDetail`: `record(SERVICE_START, "restart=true")` writes one line matching `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z service-start restart=true$` with clock `1_700_000_000_000`.
    - `detailIsSanitised`: the detail `"Ada's Mac 10.0.0.5"` is written as `Ada_s_Mac_10.0.0.5`. No character outside `[A-Za-z0-9_=.,-]` survives.
    - `keepsNewest500Lines`: 1,234 records with detail `n=<i>`. The file then has between 500 and 600 lines, and its last line ends with `n=1233`.
    - `recordNeverThrows`: a file in a deleted directory still returns normally.
  - `PairedMacsBlobTest`:
    - `absentFileIsConfirmedEmpty`: `decode(null) { it }` == `Macs(emptyList())`.
    - `goodBlobReadsMacs`: the JSON of one `PairedMac` comes back equal.
    - `providerExceptionIsUnreadable`: decrypt throws `java.security.ProviderException` → `Unreadable("ProviderException")`.
    - `generalSecurityExceptionIsUnreadable`: decrypt throws `javax.crypto.AEADBadTagException` → `Unreadable("AEADBadTagException")`.
    - `badJsonIsUnreadable`: decrypt returns `"{"` → `Unreadable("SerializationException")`, or the subclass's simple name.
  - `BootDecisionTest`:
    - `unreadableStoreNeverStopsService`: `shouldSelfStop(false, confirmedEmpty = false)` is false.
    - `pairingUnderWayNeverStops`: `shouldSelfStop(true, true)` is false.
    - `confirmedEmptyStops`: `shouldSelfStop(false, true)` is true.
    - `appOpenStartsServiceWheneverPaired`: `shouldStartService(1)` is true and `shouldStartService(0)` is false. This pins the decision `onResume` now uses on its own. Removing the `running` gate is checked on the device in Step 6, and through the `app-open flag= probe=` log line.
- [ ] **Step 3: Run** `cd android && ./gradlew :app:testOssDebugUnitTest`. Expected: FAIL (unresolved references).
- [ ] **Step 4: Implement.**
  - **`KeepAliveLog`:** appends under a lock on `Dispatchers.IO`, and rewrites the file with the newest `maxLines` when it passes `maxLines + 100`. Errors are swallowed.
  - **`PairedMacsBlob.decode`:** has the decode logic that is now in `EncryptedPairedMacStore.load()`, catching `GeneralSecurityException`, `ProviderException` and `SerializationException`.
    - `all()` keeps 0.1's meaning: `Unreadable` reads as an empty list. It also records `STORE_UNREADABLE <causeClass>`.
  - **`ServiceProbe`:** `getRunningServices(Int.MAX_VALUE)`, with `@Suppress("DEPRECATION")`; it still returns the caller's own services. It matches `service.className == ConnectionService::class.java.name && foreground`.
  - **`ConnectionService`:**
    - Record `SERVICE_CREATE`, `SERVICE_START restart=<intent==null>`, `SERVICE_DESTROY` and `STATE <state class name>`.
    - **The `NotPaired` branch of `onState`:**
      - If `BootDecision.shouldSelfStop(pairing, graph.noMacPaired())` is true, record `SERVICE_SELF_STOP no-mac`, then `stopForeground` and `stopSelf` as before.
      - Otherwise record `STATE notpaired-unreadable`, wait 30 s, then `graph.manager.kick()`. Do this once per `NotPaired` episode; a later `NotPaired` starts a new wait.
  - **`MainActivity.onResume`:**
    - Drop the `!ConnectionService.running` gate: start whenever `!graph.noMacPaired()`. Starting a running service only re-runs `onStartCommand`, and that is harmless.
    - Record `APP_OPEN flag=<ConnectionService.running> probe=<ServiceProbe.connectionServiceRunning>`. A line `flag=true probe=false` is direct proof of H1.
  - **`AppGraph` init:** record `PROCESS_START`, and on API 30+ add `exit=<reason>` from `getHistoricalProcessExitReasons(packageName, 0, 1)`: `ApplicationExitInfo.reason`, an int.
- [ ] **Step 5: Run the tests.** `./gradlew :app:testOssDebugUnitTest :app:assembleOssDebug :app:lintOssDebug`. Expected: PASS.
- [ ] **Step 6: Device check** (rulings R25 and R31 of 0.1 apply: adb is allowed; the Mac is am-mac-sim).
  - Install the APK. Pair against `am-mac-sim --identity protocol/testdata/identities/mac.p12 --state-dir <tmp> --port 0 --auto-confirm`.
  - Run `adb shell am stopservice io.github.anmirror.phone/.service.ConnectionService`, then open the app.
  - `adb shell run-as io.github.anmirror.phone cat files/keepalive-events.log` shows `service-destroy`, `app-open flag=false probe=false`, `service-create`.
  - `adb shell dumpsys activity services io.github.anmirror.phone` lists `ConnectionService` with `isForeground=true`.
- [ ] **Step 7: Commit.** `git commit -m "fix(phone): restart the service on app open, never self-stop on an unreadable store, keep-alive event log"`.

### Task 2: Protocol: `liveness.v1`, `background_restricted`, TCP keepalive (SPEC and docs)

*Platform: protocol (both generated codes) and docs. Depends on: nothing. Parallel: with Task 1.*

**Files:**
- Modify:
  - `protocol/proto/anmirror/v1/status.proto`
  - `protocol/SPEC.md`
  - `protocol/tools/make_vectors.py`
  - `protocol/vectors/framing.json`
  - the generated code (`scripts/gen-proto.sh`)
  - `docs/PRD.md` F-02
  - `docs/ARCHITECTURE.md` §3.3 and §5
- Test:
  - `mac/Packages/AMKit/Tests/AMProtocolTests/VectorTests.swift`
  - `android/core/protocol/src/test/.../VectorTest.kt`

**Interfaces:**
- Produces `bool background_restricted = 5;` in `StatusUpdate`, with the comment "true: not exempt from battery optimisation, so the phone may disconnect while locked. Absent (false) from older phones." It is generated as Swift `backgroundRestricted` and Kotlin `backgroundRestricted`.
- Produces the capability string `liveness.v1`. Its constants are defined in Tasks 3 and 4.

- [ ] **Step 1: Write the SPEC changes.**
  - **§3 table:** the ping row becomes `system.ping` / `system.pong` | either / reply | `Ping` / `Pong` | SYSTEM.
  - **"Capabilities":** add "The 0.1 keep-alive patch adds `liveness.v1` (section 7)." `liveness.v1` is a property of the connection, not a feature channel.
  - **§7:** keep the 0.1 text as "Without `liveness.v1`". Add "With `liveness.v1` shared", holding the "Protocol values (exact)" bullets of this plan and the reason in one sentence: an idle phone must not need its own timer, because its CPU may be suspended; it wakes on an incoming packet.
  - **The user-visible paragraph:**
    - "Disconnected" shows immediately when the connection closes.
    - It shows within 2 minutes when a `liveness.v1` phone vanishes, and within 75 s for a phone without it.
  - **§1:** add "Both sides SHOULD enable TCP keepalive (idle 60 s, interval 10 s, 3 probes) on control and bulk connections. It does not replace §7: a peer's kernel answers keepalive probes even when its app is frozen."
  - **§13:** add one line pointing to §1's keepalive.
  - **PRD F-02 acceptance:** "within 2 minutes when the phone vanishes (75 s with phones older than the 0.1 keep-alive patch)".
  - **ARCHITECTURE §3.3** keep-alive bullet: "Mac-driven ping every 30 s (`liveness.v1`), phone answers, TCP keepalive on all sockets". **§5:** the watchdog, and the battery-exemption step after pairing.
- [ ] **Step 2: Write the failing tests.** Add two `framing.json` vectors with decode tests on both sides:
  - `ping_from_mac`: channel SYSTEM, id 4, `system.ping`, empty payload. Tests `pingFromMacVectorDecodes` (Swift and Kotlin).
  - `status_update_background_restricted`: channel STATUS, id 6, `status.update`, `{battery_percent: 40, signal_level: 2, network: WIFI, background_restricted: true}`. The test `statusBackgroundRestrictedVectorDecodes` asserts `backgroundRestricted == true` and `batteryPercent == 40`.
- [ ] **Step 3: Run** `swift test --package-path mac/Packages/AMKit --filter AMProtocolTests` and `cd android && ./gradlew :core:protocol:test`. Expected: FAIL.
- [ ] **Step 4: Add the field, regenerate, and add the vectors to `make_vectors.py`.** Run `scripts/gen-proto.sh`, `scripts/gen-proto.sh --check` and `python3 -I protocol/tools/make_vectors.py --check`.
- [ ] **Step 5: Run the tests.** Expected: PASS. The full Swift and Android suites pass, and `scripts/interop-test.sh` passes 9/9.
- [ ] **Step 6: Commit.** `git commit -m "feat(protocol): liveness.v1 Mac-driven keep-alive, TCP keepalive, status background_restricted"`.

### Task 3: Mac: Mac-driven pings, missed-interval drop, TCP keepalive, menu note

*Platform: Mac (AMKit, app, am-mac-sim). Depends on: Task 2. Parallel: with Task 4 (and Task 1).*

**Files:**
- Create:
  - `mac/Packages/AMKit/Sources/ConnectionCore/Liveness.swift`
  - `Tests/ConnectionCoreTests/LivenessMonitorTests.swift`
  - `MacServerLivenessTests.swift`
  - `TLSParametersTests.swift`
- Modify:
  - `Sources/ConnectionCore/MacServer.swift`:
    - the init;
    - `handle(_:in:)`, `.active` case;
    - `handleHello`;
    - `drop`;
    - `Session`.
  - `TLSParameters.swift`
  - `Sources/FeatureStatus/PhoneStatusModel.swift`
  - `StatusFormatter.swift`
  - `Sources/am-mac-sim/main.swift`
  - `scripts/interop-test.sh` (case 2's status regex only)
  - `Tests/ConnectionCoreTests/MacServerTests.swift` (`startServer` gains `pingInterval` and `missedPingLimit`)
  - `Tests/FeatureStatusTests/StatusFormatterTests.swift`
  - `mac/App/AppModel.swift` (`capabilities` += `"liveness.v1"`)
  - `MenuContent.swift`
  - `Localizable.xcstrings`

**Interfaces:**
- Consumes `AMStatusUpdate.backgroundRestricted` (Task 2).
- Produces:

```swift
public enum Liveness { public static let capability = "liveness.v1" }
enum LivenessAction: Equatable { case sendPing, drop }
struct LivenessMonitor {
    init(missedLimit: Int = 3)          // a new monitor counts the hello as received
    mutating func received()           // any incoming envelope
    mutating func tick() -> LivenessAction
}
// MacServer.init gains: pingInterval: Duration = .seconds(30), missedPingLimit: Int = 3
// PhoneStatus gains: public var backgroundRestricted: Bool (init parameter defaulted to false)
extension StatusFormatter { public static func backgroundNote(_ s: PhoneStatus) -> String? }
```

- am-mac-sim flags:
  - `--liveness` adds `liveness.v1` to its capabilities.
  - `--ping-interval-ms <n>` sets `pingInterval`.
  - Neither is on by default, so cases 1–9 keep their `shared=` lines.

- [ ] **Step 1: Write the failing tests.**
  - **`LivenessMonitorTests`:**
    - `firstTickAfterHelloSendsPing`: a new monitor's `tick()` is `.sendPing`.
    - `dropsOnFourthTickWithNothingReceived`: ticks give `.sendPing, .sendPing, .sendPing, .drop`. That is 3 silent intervals after the hello's, so a drop 90–120 s after the last message.
    - `anyMessageResetsTheCount`: 3 silent ticks, then `received()`, then the next 3 ticks are `.sendPing` and the 4th is `.drop`.
    - `customLimit`: with `missedLimit: 1`, ticks give `.sendPing, .drop`.
  - **`MacServerLivenessTests`** (real TLS, `TestPhone`, `pingInterval: .milliseconds(100)`):
    - `macPingsLivenessPhone`:
      - Hello with `["status.v1", "find.v1", "liveness.v1"]`.
      - A `system.ping` on channel `.system` arrives within 1 s.
      - Its `replyTo` is 0 and its `id` is above the hello's id.
    - `answeringPhoneStaysConnected`:
      - The phone answers every ping with a `system.pong`, `replyTo` = the ping's id, for 1.5 s.
      - `server.state != .idle` throughout, and there is no `.disconnected` in the log.
    - `silentLivenessPhoneIsDroppedAfterThreeMissedIntervals`:
      - The phone never answers.
      - `.disconnected(known)` arrives within 2 s.
      - The phone received at least 3 pings before its connection ended.
    - `livenessSessionIgnoresSilenceTimeout`:
      - `silenceTimeout: .milliseconds(150)`, `pingInterval: .milliseconds(200)`, and a silent phone.
      - At 300 ms the server is still not `.idle`, because the 75 s-style rule no longer applies.
      - It is `.idle` within 2 s.
    - `legacyPhoneGetsNoPings`:
      - Hello without `liveness.v1`.
      - No `system.ping` arrives in 500 ms.
      - The existing `silenceTimeoutDropsPhone` still passes unchanged.
    - `pongIsNotForwardedToFeatures`:
      - `server.onMessage` collects envelopes.
      - After a liveness phone sends 3 pongs and one `status.update`, `onMessage` saw only the `status.update`.
  - **`TLSParametersTests`:** `serverAndClientEnableTcpKeepalive`. For `TLSParameters.server(...)` and `.client(...)` (test identity), `defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options` has `enableKeepalive == true`, `keepaliveIdle == 60`, `keepaliveInterval == 10`, `keepaliveCount == 3` and `noDelay == true`.
  - **`StatusFormatterTests`:**
    - `backgroundNoteOnlyWhenRestricted`: `"Phone may disconnect when locked"` for `backgroundRestricted: true`, and `nil` for false.
    - `applyReadsBackgroundRestricted`: `PhoneStatusModel.apply` of an update with the flag set gives `status?.backgroundRestricted == true`.
- [ ] **Step 2: Run** `swift test --package-path mac/Packages/AMKit --filter "ConnectionCoreTests|FeatureStatusTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **`LivenessMonitor`:** a flag `receivedSinceTick` (true at init) and a count `missed`. `tick()` resets `missed` when the flag is set and increments it otherwise, clears the flag, and returns `.drop` when `missed >= missedLimit`.
  - **`MacServer`, when a hello makes a session `.active` with `Liveness.capability` in `shared`:**
    - Cancel `session.silence` and set `session.liveness = LivenessMonitor(missedLimit:)`.
    - Start `session.pinger`, a `Task` on the main actor: `Task.sleep(for: pingInterval)`, then `tick()`.
      - `.sendPing` posts `.ping, AMPing(), channel: .system`.
      - `.drop` calls `drop(session)`.
  - **`handle`:** calls `session.liveness?.received()` for liveness sessions instead of `armSilence`. Every other session keeps `armSilence`.
  - **In `.active`, a `system.pong` is consumed,** not passed to `onMessage`, in both modes.
  - **`drop`:** cancels `pinger`.
  - **TLS:** `TLSParameters` sets the four keepalive values on both TCP option sets, as `static let` constants. `BulkServer` already uses `.server`, so bulk sockets get them too.
  - **Menu:** shows `StatusFormatter.backgroundNote` as a `Text` under the status line in `MenuContent` (add the string to `Localizable.xcstrings`).
  - **`AppModel.capabilities`:** add `"liveness.v1"`.
  - **am-mac-sim:**
    - Add the two flags.
    - Append ` restricted=<bool>` to its `EVENT status` line, and update interop case 2's regex to `... network=wifi restricted=false$`.
- [ ] **Step 4: Run** `swift test --package-path mac/Packages/AMKit`, `xcodegen --spec mac/project.yml`, and the Debug and Release `xcodebuild`. Expected: PASS, and `scripts/interop-test.sh` passes 9/9.
- [ ] **Step 5: Commit.** `git commit -m "feat(mac): Mac-driven liveness pings, 3-interval drop, TCP keepalive, background note"`.

### Task 4: Phone core: liveness state machine, fallback ping, backoff cap, TCP keepalive, interop

*Platform: Android `core/connection`, `feature/status`, `phone-sim`, interop script. Depends on: Task 2 (and Task 3's sim for Step 7). Parallel: with Task 3 and Task 1.*

**Files:**
- Create:
  - `android/core/connection/src/main/kotlin/io/github/anmirror/connection/Liveness.kt`
  - `SocketTuner.kt`
  - `android/tools/phone-sim/src/main/kotlin/io/github/anmirror/phonesim/JdkKeepAliveTuner.kt`
  - `src/test/.../PhoneLivenessTest.kt`
  - `PhoneSessionLivenessTest.kt`
- Modify:
  - `PhoneSession.kt`
  - `ConnectionManager.kt` (`ConnectionTiming`, the constructor, `runConnected`, the class doc)
  - `TlsConnector.kt`
  - `Fakes.kt` (`FakeMac.sendPing()`)
  - `ConnectionManagerTest.kt` (the rig passes `uptimeMs`; the timing tests)
  - `TlsConnectorTest.kt`
  - `android/feature/status/.../PhoneStatus.kt` (+ `StatusPublisherTest`)
  - `phone-sim/.../Main.kt`
  - `scripts/interop-test.sh`

**Interfaces:**
- Produces:

```kotlin
const val LIVENESS_CAPABILITY = "liveness.v1"
sealed interface LivenessStep {
    data object SendPing : LivenessStep
    data class WaitUntil(val atMs: Long) : LivenessStep
    data object Dead : LivenessStep
}
/** Times are monotonic uptime ms (stop in deep sleep, like coroutine delay): time asleep never counts against the Mac. */
class PhoneLiveness(
    macDriven: Boolean, pingIntervalMs: Long, fallbackIdleMs: Long, pongTimeoutMs: Long, startMs: Long,
) {
    fun onIncoming(nowMs: Long, isPong: Boolean)
    fun onPingSent(nowMs: Long)
    fun requestPing()            // a kick: next() returns SendPing
    fun next(nowMs: Long): LivenessStep
}
class PhoneSession(
    channel: ControlChannel, shared: Set<String>,
    pingIntervalMs: Long = 30_000, pongTimeoutMs: Long = 10_000, fallbackIdleMs: Long = 45_000,
    uptimeMs: () -> Long = { System.nanoTime() / 1_000_000 },
) { suspend fun run(pingNow: ReceiveChannel<Unit>? = null, onMacPing: (() -> Unit)? = null, onMessage: suspend (Envelope) -> Unit): SessionEnd }
// ConnectionTiming: fallbackIdleMs = 45_000; backoffMs = [1_000, 2_000, 4_000, 5_000, 5_000, 5_000, 15_000, 30_000]
// ConnectionManager(..., uptimeMs: () -> Long = { System.nanoTime() / 1_000_000 })
fun interface SocketTuner { fun tune(socket: java.net.Socket) }
object TcpKeepAlive { const val IDLE_S = 60; const val INTERVAL_S = 10; const val COUNT = 3; val BASIC: SocketTuner }  // BASIC: keepAlive = true
// TlsConnector(identity, connectTimeoutMs = 3000, tuner: SocketTuner = TcpKeepAlive.BASIC): tuner runs right after raw.connect, for control and bulk dials
// feature/status PhoneStatus gains: val backgroundRestricted: Boolean = false (toProto sets it)
```

- phone-sim:
  - `--liveness` adds `liveness.v1` to the hello.
  - It always passes `JdkKeepAliveTuner`, which sets `ExtendedSocketOptions` `TCP_KEEPIDLE`, `TCP_KEEPINTERVAL` and `TCP_KEEPCOUNT` to the `TcpKeepAlive` values, best effort.
  - It prints `EVENT mac-ping` from `onMacPing`.

- [ ] **Step 1: Write the failing `PhoneLivenessTest`.** Use `startMs = 0`, a 30 s interval, a 45 s fallback and a 10 s pong timeout.
  - `legacyPingsThirtySecondsAfterLastPong`:
    - `next(0) == WaitUntil(30_000)`.
    - `next(30_000) == SendPing`.
    - After `onPingSent(30_000)` and `onIncoming(35_000, isPong = true)`, `next(35_000) == WaitUntil(65_000)`.
  - `legacyDeadTenSecondsAfterUnansweredPing`: after `onPingSent(30_000)`, `next(39_999) == WaitUntil(40_000)` and `next(40_000) == Dead`.
  - `legacyModeIgnoresNonPongTraffic`: `onPingSent(30_000)`, `onIncoming(31_000, isPong = false)`, then `next(40_000) == Dead`.
  - `macDrivenWaitsFortyFiveSecondsOfQuiet`: `next(0) == WaitUntil(45_000)`; after `onIncoming(30_000, false)`, `next(30_000) == WaitUntil(75_000)`.
  - `macDrivenAnyMessageAnswersFallbackPing`: `onPingSent(45_000)`, `onIncoming(50_000, false)`, then `next(50_000) == WaitUntil(95_000)`.
  - `macDrivenDeadTenSecondsAfterUnansweredFallbackPing`: after `onPingSent(45_000)`, `next(54_999) == WaitUntil(55_000)` and `next(55_000) == Dead`.
  - `requestPingSendsAtOnceInBothModes`: for each mode, `requestPing()` then `next(1) == SendPing`.
- [ ] **Step 2: Write the failing session, manager and connector tests.**
  - **`PhoneSessionLivenessTest`** (`runTest`, `MemoryWire` pair from `Fakes.kt`, `uptimeMs = { testScheduler.currentTime }`):
    - `answersMacPingWithPongReplyTo`: the Mac side sends a ping with id 7. The phone writes `system.pong` with `replyTo == 7` before virtual time advances, and `onMacPing` ran once.
    - `macDrivenSessionSendsNoTimerPingWhileMacPings`:
      - `shared` contains `liveness.v1`.
      - The Mac side pings every 30 s for 300 s.
      - The phone sent 0 `system.ping` and 10 `system.pong`, and the session is still running.
    - `macDrivenSessionFallsBackToOwnPingAfter45sQuiet`: the Mac is silent. At 44_999 ms 0 pings were sent; at 45_001 ms there is 1.
    - `macDrivenSessionEndsAfterUnansweredFallbackPing`: `run` returns `SessionEnd.PONG_TIMEOUT` at 55_000 ms, not before 54_999 ms.
    - `kickPingsAtOnceInMacDrivenMode`: an element on `pingNow` at 10_000 ms gives one phone ping at 10_000 ms.
  - **`ConnectionManagerTest`:**
    - Update `defaultTimingIsTheSpecValues`:
      - the backoff for attempts 0..9 is `[1_000, 2_000, 4_000, 5_000, 5_000, 5_000, 15_000, 30_000, 30_000, 30_000]`;
      - `fallbackIdleMs == 45_000`;
      - every other value is unchanged.
    - Replace `backoffCapsAt60sAfterSixAttempts` with `backoffCapsAt30sAfterSixAttempts`: after `advanceTimeBy(130_001)`, the dial times are `[0, 1_000, 3_000, 7_000, 12_000, 17_000, 22_000, 37_000, 67_000, 97_000, 127_000]`. The kick part of the old test stays.
    - `burstOfKicksDialsOnce`:
      - No Mac answers.
      - At virtual 23_000 ms (in the 15 s wait after the dial at 22_000), call `kick()` three times with no `runCurrent()` between them.
      - Exactly one dial in `[23_000, 23_999]`. The next dial is at 24_000, because the backoff starts over.
    - The existing `reconnectsWhenPongMissing` and `keepsConnectionWhilePongsArrive` pass unchanged. Their `FakeMac` lists no `liveness.v1`.
  - **`TlsConnectorTest`:** `tunerRunsOnEveryDialedSocket`. A recording tuner sees one connected socket per `connect`, and one per `dialPinned`.
  - **`StatusPublisherTest`:** `backgroundRestrictedGoesOnTheWire`. `PhoneStatus(..., backgroundRestricted = true).toProto().backgroundRestricted` is true.
- [ ] **Step 3: Run** `cd android && ./gradlew :core:connection:test :feature:status:test`. Expected: FAIL.
- [ ] **Step 4: Implement.**
  - **`PhoneSession.run`:** drives `PhoneLiveness`. `macDriven = LIVENESS_CAPABILITY in shared`. The pinger loop:
    - asks `next(uptimeMs())`;
    - on `SendPing`, sends and calls `onPingSent`;
    - on `WaitUntil`, waits for `delay(at - now)`, an incoming signal or `pingNow`;
    - on `Dead`, finishes with `PONG_TIMEOUT`.
  - **The reader loop:** calls `onIncoming(uptimeMs(), isPong)` for every envelope, and keeps answering `system.ping` inline (then `onMacPing?.invoke()`).
  - **`ConnectionManager`:** passes `timing.fallbackIdleMs` and `uptimeMs` through. The "matured" timer stays at `pingIntervalMs`. The class doc gets the new backoff and the two keep-alive modes.
  - **`TlsConnector.dial`:** calls `tuner.tune(raw)` right after `raw.connect`, inside `runCatching`, and on failure logs nothing beyond the exception class.
  - **phone-sim:** add the flag and the tuner.
- [ ] **Step 5: Run the tests.** `./gradlew test :tools:phone-sim:installDist`. Expected: PASS.
- [ ] **Step 6: Add interop cases 10–12 to `scripts/interop-test.sh`.**
  - **`stop_all` and `cleanup`:** send `kill -CONT` to each pid before `kill`. A stopped JVM ignores SIGTERM until it is continued, and `wait` would hang.
  - **Case 10, "liveness: Mac pings keep a quiet phone connected":**
    - `start_mac c10 --auto-confirm --liveness --ping-interval-ms 200`; phone-sim `pair ... --auto-confirm --liveness`.
    - `need` both sides' `EVENT connected ... shared=find\.v1,liveness\.v1,status\.v1`.
    - `sleep 3`. Then `grep -c '^EVENT mac-ping$'` on the phone log is ≥ 10, and the Mac log has no `^EVENT disconnected`.
  - **Case 11, "liveness: frozen phone is dropped":**
    - The same setup.
    - After connected, `kill -STOP "$PHONE_PID"`.
    - `need "$MAC_LOG" '^EVENT disconnected [0-9a-f]+$' ... 3`: within 3 s. The limit is 3 × 200 ms, plus TLS close.
    - Then `kill -CONT "$PHONE_PID"`.
  - **Case 12, "liveness Mac, legacy phone: no pings":**
    - `--liveness --ping-interval-ms 200` on the Mac only.
    - `need` phone `EVENT connected shared=find\.v1,status\.v1$`.
    - `sleep 2`. Then the phone log has no `^EVENT mac-ping$`, and the Mac log has no `^EVENT disconnected`.
  - **Summary line:** "all 12 cases passed".
- [ ] **Step 7: Run** `scripts/interop-test.sh` (with Task 3 merged). Expected: `interop: all 12 cases passed`.
- [ ] **Step 8: Commit.** `git commit -m "feat(phone-core): liveness.v1 fallback ping, 30 s backoff cap, TCP keepalive, interop 10-12"`.

### Task 5: Phone app: watchdog, screen-on kick, keepalive sockets, capability

*Platform: Android app. Depends on: Tasks 1 and 4. Parallel: none on the Android app lane (it can overlap Task 3).*

**Files:**
- Create:
  - `android/app/src/main/kotlin/io/github/anmirror/phone/service/KeepAliveWatchdog.kt`
  - `KeepAliveWatchdogReceiver.kt`
  - `ScreenOnKicker.kt`
  - `ReconnectNotice.kt`
  - `.../platform/AndroidKeepAliveTuner.kt`
  - `app/src/test/.../WatchdogDecisionTest.kt`
- Modify:
  - `AndroidManifest.xml` (the receiver, `exported="false"`)
  - `ConnectionService.kt` (schedule and cancel the watchdog; register `ScreenOnKicker`; record `NETWORK`)
  - `BootReceiver.kt` (schedule after start)
  - `AppGraph.kt` (`CAPABILITIES` += `"liveness.v1"`; `TlsConnector(identity, tuner = AndroidKeepAliveTuner())`)
  - `strings.xml` (`reconnect_*`)

**Interfaces:**
- Consumes:
  - `ServiceProbe.connectionServiceRunning`, `graph.noMacPaired()`, `keepAliveLog` (Task 1);
  - `SocketTuner`, `TcpKeepAlive` and `LIVENESS_CAPABILITY` (Task 4).
- Produces:

```kotlin
enum class WatchdogAction { CANCEL, START_SERVICE, KICK, NOTHING }
object WatchdogDecision {
    fun pairedForWatchdog(confirmedEmpty: Boolean): Boolean = !confirmedEmpty   // an unreadable store counts as paired
    fun decide(paired: Boolean, serviceRunning: Boolean, connected: Boolean): WatchdogAction
}
class KeepAliveWatchdog(context: Context) { fun schedule(); fun cancel() }     // 15 min, setAndAllowWhileIdle ELAPSED_REALTIME_WAKEUP
class ScreenOnKicker(context: Context, onScreenOn: () -> Unit) { fun start(); fun stop() }   // ACTION_SCREEN_ON, context-registered
object ReconnectNotice { fun post(context: Context); fun clear(context: Context) }
class AndroidKeepAliveTuner : SocketTuner   // keepAlive = true, then Os.setsockoptInt(IPPROTO_TCP, 4/5/6, TcpKeepAlive values) on a dup fd
```

- [ ] **Step 1: Write the failing `WatchdogDecisionTest`.**
  - `nothingPairedCancels`: `decide(false, *, *) == CANCEL` for all four combinations.
  - `pairedAndNotRunningStartsService`: `decide(true, false, false) == START_SERVICE`.
  - `runningButNotConnectedKicks`: `decide(true, true, false) == KICK`.
  - `runningAndConnectedDoesNothing`: `decide(true, true, true) == NOTHING`.
  - `unreadableStoreCountsAsPaired`: `pairedForWatchdog(confirmedEmpty = false)` is true and `pairedForWatchdog(confirmedEmpty = true)` is false. The receiver passes `graph.noMacPaired()`.
- [ ] **Step 2: Run** `./gradlew :app:testOssDebugUnitTest`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **The receiver:** `goAsync()`, then in `graph.scope`:
    - reads `paired`, `ServiceProbe` and `manager.state is Connected`;
    - records `WATCHDOG <action>`;
    - acts.
  - **`START_SERVICE`:** `ConnectionService.start(ctx)`. When it returns false (start refused from the background: not exempt), `ReconnectNotice.post`.
  - **`KICK`:** `graph.manager.kick()`.
  - **Re-arm** unless the action is `CANCEL`. In every path, call `pending.finish()` in `finally`.
  - **`ConnectionService.onCreate`:** `watchdog.schedule()` and `ReconnectNotice.clear()`.
  - **Self-stop (`no-mac`):** `watchdog.cancel()`.
  - **`ScreenOnKicker`:** calls `graph.manager.kick()` and records `SCREEN_ON`. A connected session then pings at once, and a disconnected one dials at once.
  - **`NetworkWatcher`'s callback:** also records `NETWORK available|lost|changed`.
  - **`ReconnectNotice`:** a silent `connection`-channel notification, id 3, tapping to `MainActivity`. Its `onResume` restart is Task 1.
- [ ] **Step 4: Run** `./gradlew test :app:assembleOssDebug :app:lintOssDebug`. Expected: PASS.
- [ ] **Step 5: Device check** against am-mac-sim (`--liveness`), screen off, unplugged.
  - `adb shell dumpsys deviceidle force-idle`, then wait 5 min. The Mac sim shows no `EVENT disconnected`.
  - `adb shell cmd alarm` lists the watchdog alarm.
  - `adb shell am broadcast -n io.github.anmirror.phone/.service.KeepAliveWatchdogReceiver` with the service stopped logs `watchdog START_SERVICE` and either restarts it or posts the notice. Record which.
  - `adb shell dumpsys deviceidle unforce` afterwards.
- [ ] **Step 6: Commit.** `git commit -m "feat(phone): keep-alive watchdog, screen-on kick, TCP keepalive sockets, liveness.v1"`.

### Task 6: Phone app: battery exemption setup, maker guidance, home row, status flag

*Platform: Android app. Depends on: Tasks 2, 4 and 5. Parallel: with Task 3 if it is still running.*

**Files:**
- Create:
  - `android/app/src/main/kotlin/io/github/anmirror/phone/MakerGuidance.kt`
  - `.../platform/Battery.kt`
  - `.../ui/KeepConnectedScreen.kt`
  - `app/src/test/.../MakerGuidanceTest.kt`
  - `BackgroundStateTest.kt`
- Modify:
  - `AndroidManifest.xml` (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, with `tools:ignore="BatteryLife"` and a comment naming F-Droid and the Play note)
  - `AppGraph.kt` (`backgroundExempt`, `makerStepDone`, `refreshBackgroundExempt()`)
  - `MainActivity.kt` (`Screen.KeepConnected`; after `PairingState.Paired`'s Continue; `refreshBackgroundExempt()` in `onResume`)
  - `ui/HomeScreen.kt` (`KeepConnectedRow` first in the list)
  - `ConnectionService.kt` (the status source carries `backgroundRestricted`)
  - `strings.xml`

**Interfaces:**
- Consumes `PhoneStatus.backgroundRestricted` (Task 4) and `KeepAliveEvent.EXEMPT` (Task 1).
- Produces:

```kotlin
enum class Maker { VIVO, XIAOMI, OPPO, SAMSUNG, HUAWEI }
object MakerGuidance { fun makerOf(manufacturer: String): Maker? }   // lowercase match on Build.MANUFACTURER
data class BackgroundState(val exempt: Boolean, val maker: Maker?, val makerStepDone: Boolean) {
    val showsPrompt: Boolean   // !exempt || (maker != null && !makerStepDone)
    val restricted: Boolean    // !exempt (the only fact the phone can read)
}
object Battery {
    fun isExempt(context: Context): Boolean                // PowerManager.isIgnoringBatteryOptimizations(packageName)
    fun requestExemptionIntent(context: Context): Intent   // ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, data "package:<pkg>"
    fun appSettingsIntent(context: Context): Intent        // ACTION_APPLICATION_DETAILS_SETTINGS
}
// AppGraph: val backgroundExempt: StateFlow<Boolean>; val makerStepDone: StateFlow<Boolean> (persisted like the feature switches); fun setMakerStepDone(); fun refreshBackgroundExempt()
```

- [ ] **Step 1: Write the failing tests.**
  - **`MakerGuidanceTest`:**
    - `vivoAndIqooMapToVivo`: `"vivo"` and `"iQOO"` give `VIVO`.
    - `xiaomiFamily`: `"Xiaomi"`, `"Redmi"` and `"POCO"` give `XIAOMI`.
    - `oppoFamily`: `"OPPO"`, `"OnePlus"` and `"realme"` give `OPPO`.
    - `samsung`: `"samsung"` gives `SAMSUNG`.
    - `huaweiAndHonor`: `"HUAWEI"` and `"HONOR"` give `HUAWEI`.
    - `unknownMakersHaveNoGuidance`: `"Google"`, `"Fairphone"` and `""` give `null`.
  - **`BackgroundStateTest`:**
    - `exemptPixelShowsNothing`: `(true, null, false)` is neither `showsPrompt` nor `restricted`.
    - `notExemptPromptsAndReportsRestricted`: `(false, null, false)` gives both true.
    - `exemptVivoPromptsUntilMakerStepDone`: `(true, VIVO, false).showsPrompt` is true; `(true, VIVO, true).showsPrompt` is false; `restricted` is false in both.
- [ ] **Step 2: Run** `./gradlew :app:testOssDebugUnitTest`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **`KeepConnectedScreen`:** shows the exact copy.
    - "Allow in the background" opens `requestExemptionIntent`. It is hidden once exempt.
    - The maker block (`keep_maker_intro` and the maker's line) and "Open app settings" appear only when `maker != null`.
    - "Done" calls `setMakerStepDone()` (when there is a maker) and returns to Main. "Not now" returns to Main.
  - **When it shows:** after `PairingState.Paired` → Continue, it opens when `showsPrompt`; otherwise the app goes to Main. Also from the home row's "Fix".
  - **`KeepConnectedRow`:** shows while `showsPrompt`, with `keep_row_title`, `keep_row_line` and the "Fix" button, and a TalkBack label of the title and line together.
  - **`refreshBackgroundExempt()`:** runs on resume and in `ConnectionService.onCreate`, and records `EXEMPT <bool>` when the value changes.
  - **The status flow:** `combine(AndroidStatusSource(this), graph.backgroundExempt) { s, e -> s.copy(backgroundRestricted = !e) }`. `StatusPublisher` then re-sends on change.
- [ ] **Step 4: Run** `./gradlew test :app:assembleOssDebug :app:lintOssDebug`. Expected: PASS.
- [ ] **Step 5: Device check** (vivo, against am-mac-sim):
  - After pairing, the screen appears with the vivo line.
  - "Allow in the background" shows the system dialog.
  - After Allow, `adb shell dumpsys deviceidle whitelist` lists the app, and the home row stays until Done.
  - Revoke the exemption in Settings → the row returns on resume, and am-mac-sim prints `EVENT status ... restricted=true` (the field Task 3 added).
- [ ] **Step 6: Commit.** `git commit -m "feat(phone): battery exemption step after pairing, maker guidance, background_restricted to the Mac"`.

### Task 7: Owner checks and results, rerun of 0.1 check (h)

*Platform: docs (runs both suites). Depends on: 1–6. Parallel: none.*

**Files:**
- Modify:
  - `docs/milestones/0.1-keepalive-results.md` (complete it)
  - `docs/milestones/0.1-results.md` (check (h): record run 1 as FAIL with its numbers, and point to the new doc for the rerun)
  - `README.md` (one line in setup: "After pairing, allow the app in the background so the phone stays connected while locked.")

- [ ] **Step 1: Write Part 1, "Measured without a phone",** with the date, the machine and the commit:
  - The Swift and Android test counts against the 8cc13a5 baseline (Swift 613, Android 536).
  - Interop 12/12.
  - The Mac Debug and Release builds.
  - **Manifest audit** (`aapt2 dump permissions`): only `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is new; no SMS; no `WAKE_LOCK` or exact-alarm permission.
  - **Log audit:** grep the non-test sources changed since `8cc13a5` for log calls and `keepAliveLog.record`. Read each hit; expect only codes, classes, booleans and counts.
- [ ] **Step 2: Write Part 2, the owner checks,** in the 0.1 file's style, each with a `PENDING` result line.
  - **(h) rerun, the pass criterion of 0.1 (h) unchanged.**
    - Release Mac app and the debug APK, paired, after the post-pairing screen with "Allow" and the vivo step done.
    - Unplugged, screen off and untouched for at least 30 min.
    - Record: the Mac menu still shows Connected, Ring works, and whether it was ever "Not connected" (open the menu every 10 min without touching the phone).
    - Then pull `adb shell run-as io.github.anmirror.phone cat files/keepalive-events.log` and paste the lines for the window.
  - **(h-2) the same with the exemption OFF and the vivo setting at its default.** The expected outcome is recorded, not required:
    - if it disconnects, the menu said "Phone may disconnect when locked" beforehand;
    - after unlocking, the phone reconnects within 10 s (screen-on kick).
  - **(h-3) 2 h overnight version of (h)**, with the exemption on: still connected, and Ring works.
  - **(k) Vanished phone:** phone Wi-Fi off while locked. The Mac shows Not connected within 2 minutes. Record the seconds.
  - **(l) Service stopped by the system:** `adb shell am stopservice io.github.anmirror.phone/.service.ConnectionService`, then lock the phone.
    - Record how long until the watchdog restarts it (target within 15–25 min, exempt), or that the "Tap to reconnect" notice appears (not exempt).
  - **(m) Battery:** `adb shell dumpsys batterystats --reset`, then 1 h idle, locked and connected. Record the app's mAh and its share. The PRD target is under 2 %/day idle; 30 s pings are the controller's starting value, and tuning is 0.9.
  - **(n) Mixed versions:**
    - Mac app from `8cc13a5` with this phone build, and this Mac app with a 0.4 phone build.
    - Both connect, and Ring works.
    - The old-Mac pairing shows the 75 s rule (Wi-Fi off → disconnected within 75 s).
- [ ] **Step 3: Write "Copy to review"** (the maker lines other than vivo are unverified), **"Decisions made during the build"** (this plan's six departures, then K1…), and **"Known limitations":**
  - The Mac's "may disconnect" line can only see Android's standard exemption. Maker settings such as vivo's are invisible to the app, so the row stays until "Done".
  - Detection of a vanished phone moves to 2 minutes.
  - A frozen app is detected only by the app-level ping, not by TCP.
  - The watchdog can restart the service from the background only when the app is exempt.
  - No wakelock is held while answering a ping. The kernel's receive wake is assumed to be enough; revisit if (h) shows pongs late by more than 1 s.
  - The Play policy note on `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
  - Android 10–15 untested.
- [ ] **Step 4: Run** `swift test --package-path mac/Packages/AMKit`, `cd android && ./gradlew test` and `scripts/interop-test.sh` once more, and paste the final counts.
- [ ] **Step 5: Commit.** `git commit -m "docs: 0.1 keep-alive patch results and owner checks"`.
