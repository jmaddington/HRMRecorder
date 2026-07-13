# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Single-purpose iOS app: connect to a BLE heart-rate strap (Garmin HRM-Pro+ or
any sensor exposing standard Heart Rate Service `0x180D`), show live BPM, and
write every reading to SQLite in real time, with CSV export. Deliberately *no*
activity/GPS recording — heart rate only. No third-party dependencies (system
`SQLite3` module + CoreBluetooth + SwiftUI).

## Product principles

These are hard constraints, not aspirations — weigh every change against them:

- **Stay simple.** The app does two things: *record HR* and *export HR*. Resist
  scope creep; a feature that doesn't serve recording or exporting probably
  doesn't belong.
- **Keep the UI uncluttered.** Default to fewer controls on screen. Prefer
  pushing secondary functions behind a button/sub-page over adding to the main
  screen. The live-BPM screen should stay clean.
- **Be ruthlessly memory-light.** This must be the *last* app a user would ever
  think to kill to free resources. No retained buffers that grow unbounded, no
  caching what can be streamed, no holding samples in memory (the fire-and-
  forget insert path exists for this reason). Background footprint matters most.

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

## Release / versioning

**After every completed feature or bug fix, bump the version so a build can
be distributed via the App Store immediately** — do this as the final step of
the work, not a separate ask:

- Bump `MARKETING_VERSION`: minor for a feature (`0.11` → `0.12`), patch for
  a bug fix once a patch component exists.
- `CURRENT_PROJECT_VERSION` (the build number) is **scoped to the current
  marketing version**. The App Store only requires it to be unique and
  increasing *within* a given `MARKETING_VERSION`, so:
  - When you bump `MARKETING_VERSION`, **reset `CURRENT_PROJECT_VERSION` to
    1** (build numbering starts fresh per marketing version).
  - For a second+ App Store upload of the *same* `MARKETING_VERSION`,
    increment `CURRENT_PROJECT_VERSION` (2, 3, …) instead.
  - The normal feature/fix flow bumps the marketing version, so the usual
    outcome is `MARKETING_VERSION` up + build reset to `1`.
- All four occurrences of each key in `project.pbxproj` (Debug+Release ×
  app+widget target) must move together — keep app and widget in lockstep.
- **Commit without asking.** The owner has standing authorization for Claude
  to `git commit` completed work directly to `main` (solo, local-only repo, no
  remote — nothing leaves the machine, and immediate commits enable fast App
  Store turnaround). This supersedes the "commits happen only when the user
  explicitly asks" line in the beads-integration block below. Still do not
  `git push` (there is no remote) unless asked. Reference the bd issue id in
  the commit message.

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
- Deployment targets: **app target iOS 18.6**, widget target **16.1**
  (project-level default 16.0 is overridden by both targets). iOS 17+ APIs
  (e.g. Swift Charts scrolling, `MagnifyGesture`) are fine in app-target
  code; keep widget code to 16.1-safe APIs.
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
## Beads issue tracker

Issues for this repo are tracked with **bd (beads)** — a dependency-aware
graph tracker backed by an embedded Dolt DB in `.beads/`. Issue prefix is
`HRMRecorder-<hash>` (e.g. `HRMRecorder-r1g`). Run `bd prime` for the full
command reference and workflow context.

```bash
bd ready                 # unblocked work ready to claim
bd show <id> --json      # issue detail (read metadata before prose)
bd update <id> --claim   # claim before starting
bd close <id> "reason"   # complete
bd create "Title" -t feature -p 2 -d "..."   # file new work
```

- Use `bd` for task tracking — **not** TodoWrite/TaskCreate or markdown TODO
  lists. Use `bd remember` for durable knowledge, not MEMORY.md files.
- `bd edit` is interactive — never use it; mutate via `bd update --<field>`.
- `bd init` set `core.hooksPath` to `.beads/hooks` (every git
  commit/push/checkout/merge in this repo now runs beads hooks) and
  auto-commits its own `.beads/` changes. Issues live in the local Dolt DB;
  `.beads/issues.jsonl` is a passive export.

**This repo has no git remote, and commits/pushes happen only when the user
explicitly asks** — this overrides beads' default "work is not complete until
`git push` succeeds" session-completion rule, which does not apply here.
<!-- END BEADS INTEGRATION -->
