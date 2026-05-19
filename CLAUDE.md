# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Single-purpose iOS app: connect to a BLE heart-rate strap (Garmin HRM-Pro+ or
any sensor exposing standard Heart Rate Service `0x180D`), show live BPM, and
write every reading to SQLite in real time, with CSV export. Deliberately *no*
activity/GPS recording — heart rate only. No third-party dependencies (system
`SQLite3` module + CoreBluetooth + SwiftUI).

## Build / run

`xcode-select` on this machine points at the Command Line Tools, not Xcode.app,
so command-line builds **must** override `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project HRMRecorder.xcodeproj -scheme HRMRecorder \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

- A **Simulator build only validates compilation.** CoreBluetooth does not
  function in the Simulator — real verification requires a physical iPhone via
  Xcode (set a signing Team; free accounts must change the bundle id
  `com.example.HRMRecorder`).
- There is **no test target** — no `test` command exists.
- SourceKit diagnostics that appear when editing a single file in isolation
  (e.g. "Cannot find type 'HRDatabase'") are false positives; trust the
  `xcodebuild` result, which compiles the whole module together.

## Project format gotchas

- The `.xcodeproj` uses an Xcode 16+ **file-system-synchronized root group**
  (`PBXFileSystemSynchronizedRootGroup`; `objectVersion` is `70` after Xcode
  rewrote the original `77` — both support synchronized groups). New `.swift`
  files dropped into `HRMRecorder/` are picked up automatically — **do not**
  hand-edit `project.pbxproj` to register sources.
- `Info.plist` lives inside the synced folder, so it is excluded from Copy
  Bundle Resources via a `PBXFileSystemSynchronizedBuildFileExceptionSet`
  (`membershipExceptions = (Info.plist)`). Any other non-source file that must
  not be bundled as a resource needs adding to that exception set, or the build
  fails with "Multiple commands produce …".
- Deployment target is **iOS 16.0**. iOS 17+ APIs will compile-fail (e.g.
  `symbolEffect` was already hit and replaced with a manual animation).
- `SWIFT_VERSION = 5.0` is intentional: it avoids Swift 6 strict-concurrency
  errors against the CoreBluetooth delegate pattern. Bumping to 6 requires
  adding actor-isolation annotations throughout `HeartRateManager`.

## Architecture

`AppModel` (in `HRMRecorderApp.swift`) is the composition root: it owns the one
`HRDatabase` and the one `HeartRateManager` (constructed with that DB), both
injected as `@EnvironmentObject`.

**Threading model is load-bearing:**

- `HeartRateManager`'s `CBCentralManager` is created with `queue: nil`, so all
  delegate callbacks, every `@Published` mutation, and the hand-off to the DB
  happen on the **main thread** by design. Keep new BLE-side work off blocking
  calls.
- `HRDatabase` funnels all SQLite access through one serial queue. Sample
  inserts are **fire-and-forget `queue.async`** (the ~1 Hz capture hot path
  must never block); reads/counts/CSV export are `queue.sync`. Preserve this
  split — making inserts synchronous would stall capture.

**Data flow:** strap notification → `HeartRateManager.ingest(_:)` parses the
GATT `0x2A37` Heart Rate Measurement packet (flags byte → 8/16-bit BPM, skin
contact, energy, R-R intervals; R-R converted from 1/1024 s units to ms) →
updates `@Published` state → if recording, `db.insertSample(...)`.

**Sessions & background resilience:** `startRecording()`/`stopRecording()`
open/close a row in `sessions`; samples carry that `session_id`. The active
session id is mirrored to `UserDefaults` (`activeSessionID`) and cleared on
stop. `HeartRateManager.init` calls `resumeActiveSessionIfNeeded()` — if a
process restart left an unfinished session, recording resumes into the *same*
session id so no samples are lost once the strap reconnects. Keep this
persistence in sync if you touch recording start/stop. CSV export streams rows
in 64 KB chunks and returns a temp-file URL surfaced through `ShareSheet`
(`UIActivityViewController`).

**Device selection:** the app does **not** auto-grab the first strap. With no
saved strap it scans and publishes `discoveredDevices` for the user to pick
(`DevicePickerView`); `select(_:)` connects and persists the chosen UUID under
`preferredDeviceUUID`. Discovered `CBPeripheral`s must stay retained in `seen`
or CoreBluetooth releases them and `select` breaks.

**Sensor identity:** on connect, the manager also discovers the Device
Information Service (`0x180A` → manufacturer/model/firmware) and Body Sensor
Location (`0x2A38`). These reads complete asynchronously *after* connect and
possibly after recording starts, so `persistDeviceInfo()` is called both when a
session starts and on each characteristic read; `HRDatabase.setSessionDevice`
uses `COALESCE` so partial/late reads accumulate without clobbering. Identity
is stored once per `sessions` row (constant per session) and denormalized onto
every CSV row via a `LEFT JOIN`.

**Connection lifecycle / staying alive in the background — three layers:**
1. `bluetooth-central` background mode (Info.plist) keeps notifications
   flowing while the strap stays connected and the screen is off.
2. `willRestoreState` + `CBCentralManagerOptionRestoreIdentifierKey`
   (`HRMRecorderCentral`) lets iOS relaunch the app in the background on a
   strap event after the system kills it.
3. On launch/restore, `autoConnectOrScan()` reconnects a restored peripheral
   or the remembered strap (via `retrievePeripherals` /
   `retrieveConnectedPeripherals`, else `autoConnectPreferred` scan), and the
   resumed session (layer above) continues recording.
   Disconnects issue a pending `connect`, which CoreBluetooth honors in the
   background. `isIdleTimerDisabled` is toggled with recording (foreground
   screen-on only — unrelated to background). There is no polling/timer and no
   unsupported background hack; this is the full extent of what iOS allows.

## SQLite notes

- `SQLITE_TRANSIENT` is hand-defined (`unsafeBitCast(-1, …)`) because the
  imported C constant is unusable from Swift; bind text with it whenever the
  Swift string is not guaranteed to outlive the `sqlite3_step`.
- WAL + `synchronous = NORMAL` is chosen for durable real-time writes without
  stalling capture; keep it.
- DB path: `Application Support/hrm.sqlite3` (shown in-app). Schema and CSV
  column layout are documented in `README.md`.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
