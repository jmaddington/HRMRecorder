# HRM Recorder — Server Sync (iOS side) Design

**Date:** 2026-05-19
**Status:** Design (for review). No implementation in this pass.
**Scope:** Add optional, user-configured upload of recorded data to a server
implementing `docs/SYNC_PROTOCOL.md`. Configuration via the iOS **Settings**
app *and* an in-app screen. OAuth 2.1 sign-in (with static-token fallback),
HTTPS only. No change to the capture path.
**Non-goals:** Real-time per-sample streaming; background `URLSession`; new
`UIBackgroundModes`; any server-specific code; dashboards.

## Product-principle check (CLAUDE.md hard constraints)

| Constraint | How honored |
|---|---|
| Stay simple — record & export only | Sync is "export, automated" — same data, pushed. Off by default; invisible until configured. |
| Keep UI uncluttered | Live-BPM screen **untouched**. Config in iOS Settings.app + one sub-screen behind a button on the existing secondary page. |
| Ruthlessly memory-light | Uploader streams samples from SQLite in bounded `LIMIT` batches; no retained buffers. Capture hot path unchanged. |
| Last app you'd kill | No new background mode. Sync is opportunistic, best-effort, cancellable. |
| Never harms capture | Mirrors `LiveActivityController`: any sync/auth failure is swallowed; recording and local data are never affected. |

## Configuration

The user asked for config "not just through the main app" → iOS Settings.app
is primary for URL + enable; OAuth sign-in is necessarily in-app (a system
web auth session cannot launch from Settings.app); status lives in-app.

### Stored state

| Key | Store | Default | Meaning |
|---|---|---|---|
| `sync.serverURL` | UserDefaults (Settings.bundle) | `""` | **Full** base URL prefix; app appends relative resource paths only |
| `sync.enabled` | UserDefaults (Settings.bundle) | `false` | Master switch |
| `sync.staticToken` | UserDefaults → migrated to Keychain on read | `""` | Optional §3.2 fallback token (secure field) |
| OAuth client reg + access + refresh tokens | **Keychain** only | — | Obtained in-app; never in plist prefs |
| `sync.cursorSampleID` | UserDefaults | `0` | Highest acked `samples.id` |
| `sync.lastResult` | UserDefaults | `""` | Last sync status (shown in-app) |

HTTPS is mandatory: a non-`https://` `sync.serverURL` is rejected at save
and at use. No insecure-HTTP toggle, no ATS exception (App-Store-clean).

### A. iOS Settings.app (`Settings.bundle`)

`Root.plist`, group "Server Sync":
- `PSToggleSwitchSpecifier` → `sync.enabled`
- `PSTextFieldSpecifier` → `sync.serverURL` (URL keyboard, no autocap/correct)
- `PSTextFieldSpecifier` → `sync.staticToken` (`IsSecure = true`) — optional;
  only used when the server doesn't offer OAuth (protocol §3.2)

> **⚠️ Project gotcha (CLAUDE.md).** The `.xcodeproj` uses a file-system-
> synchronized root group. `Settings.bundle` is a *resource*; like
> `Info.plist` it must be added to the
> `PBXFileSystemSynchronizedBuildFileExceptionSet` `membershipExceptions`,
> or the build fails "Multiple commands produce …". This is resource
> membership, **not** source registration — new `.swift` files are still
> auto-picked-up.

### B. In-app "Server Sync" screen

A row on the existing secondary/Sessions page (not the live screen) →
`ServerSyncView`: shows the URL/enable (read from the same UserDefaults),
a **Sign in** button (OAuth) / static-token note, a **Test connection**
button (`GET ping`), and read-only status (`sync.lastResult`, cursor,
pending-sample count, signed-in state). Sign-in must be here because OAuth
needs an in-app web auth session.

## Components

New Swift files (auto-picked-up by the synced group — no pbxproj source edits):

- `SyncSettings.swift` — typed accessors over UserDefaults; registers
  defaults in `AppModel.init`; HTTPS/URL validation; static-token →
  Keychain migration.
- `SyncAuth.swift` — auth coordinator. Calls `GET ping` to discover
  `auth.mode`. OAuth path: RFC 8414 discovery, RFC 7591 dynamic client
  registration, Authorization Code + PKCE (S256) via
  `ASWebAuthenticationSession` with redirect `hrmrecorder://oauth-callback`,
  token+refresh in Keychain, silent refresh on `401`. Token path: read
  Keychain static token. Exposes `currentBearer() async -> String?`.
- `SyncUploader.swift` — the engine (below). Owned by `AppModel`.
- `ServerSyncView.swift` — the in-app screen.

`HRDatabase.swift` gains **read-only** helpers (all `queue.sync`, all
bounded — consistent with the existing reads/CSV split; the fire-and-forget
insert path is untouched):

- `maxSampleID() -> Int`
- `samplesForUpload(afterID:limit:) -> [SampleRow]` —
  `SELECT id,session_id,ts,bpm,rr_ms,contact,energy_kj,device_id FROM
   samples WHERE id > ? ORDER BY id LIMIT ?` (streamed, `limit` ≤ batch cap)
- `sessionsForUpload() -> [SessionRow]`, `devicesForUpload() -> [DeviceRow]`

A new URL scheme `hrmrecorder://` is registered in `Info.plist`
(`CFBundleURLTypes`) for the OAuth redirect — the only `Info.plist` change.

## Auth flow (protocol §3)

1. `GET <base>/ping` (unauthenticated) → `auth.mode`.
2. `oauth` → discover (8414) → register (7591) → ASWebAuthenticationSession
   (PKCE S256) → tokens to Keychain. The **refresh token** keeps the
   background uploader working unattended; user signs in once. On
   jmdashboard this is its existing OAuth 2.1 server (same one used for
   `/api/v1/` & MCP) — no server changes.
3. `token` (or `ping` unreachable / no `auth`) → use the static token from
   Settings (Keychain).
4. Each request: `Authorization: Bearer <currentBearer()>`. On `401`,
   refresh once; on refresh failure surface "Sign in again" in
   `sync.lastResult` — recording untouched.

## Upload engine

`SyncUploader`: `ObservableObject` on a dedicated serial queue, one default
`URLSession` (not background — minimal footprint).

**Triggers** (debounced; in-flight sync coalesces):
1. `HeartRateManager.stopRecording()` / `endSession()` — primary.
2. `ScenePhase` → `.background` / `.active` (crash-resumed & mid-recording).
3. Backoff retry timer after a transient failure, only while `sync.enabled`.

**Never** triggered from `HeartRateManager.ingest(_:)` (the 1 Hz path).

Algorithm = `SYNC_PROTOCOL.md` §8 (ensure token → POST devices → POST
sessions → loop POST samples advancing cursor → cursor repair via
`GET sessions/{id}` when local state lost). Every network/HTTP/auth error is
caught, recorded in `sync.lastResult`, retried later; recording, the DB, and
the live UI are never affected; no local data is ever deleted by a sync.

## Versioning

Per CLAUDE.md, the implementing change bumps `MARKETING_VERSION` (minor) and
resets `CURRENT_PROJECT_VERSION` to 1 across all four pbxproj occurrences
(app + widget, Debug + Release), as the final step.

## Verification (no test target)

- Throwaway single-file mock server under `docs/` (reference, not in build)
  implementing the protocol incl. an OAuth stub, asserting idempotency &
  cursor behavior.
- Manual device matrix: OAuth sign-in & silent refresh; expired-refresh →
  "sign in again"; static-token server; fresh sync; mid-recording sync;
  kill-and-resume; airplane-mode → reconnect; reinstall (cursor repair);
  wrong URL (404); non-HTTPS URL rejected; over-cap (413 → halve).
- `jmdashboard` integration suite covers the server side end-to-end.

## Work tracking (beads, filed at implementation)

- `feat: Settings.bundle + SyncSettings (HTTPS-only, full base URL)`
- `feat: SyncAuth — OAuth 2.1 (PKCE, dyn-reg, refresh) + static fallback`
- `feat: HRDatabase read-only upload queries (bounded, memory-light)`
- `feat: SyncUploader engine (idempotent, cursor, backoff)`
- `feat: ServerSyncView (in-app sign-in + status + Test connection)`
- `docs: ship SYNC_PROTOCOL reference mock server`
- `chore: version bump`

(`SyncUploader` depends on `SyncAuth` + the DB queries.) Filed via `bd` at
implementation time, not now.

## Files changed (at implementation)

| File | Change |
|---|---|
| `HRMRecorder/SyncSettings.swift` | New |
| `HRMRecorder/SyncAuth.swift` | New — OAuth 2.1 + static fallback |
| `HRMRecorder/SyncUploader.swift` | New — upload engine |
| `HRMRecorder/ServerSyncView.swift` | New — in-app config/status/sign-in |
| `HRMRecorder/HRDatabase.swift` | Add read-only upload queries; insert path unchanged |
| `HRMRecorder/HRMRecorderApp.swift` | `AppModel` owns uploader/auth; register defaults |
| `HRMRecorder/HeartRateManager.swift` | Trigger uploader on `stopRecording()` only |
| `HRMRecorder/ContentView.swift` | One nav row to `ServerSyncView` on the secondary page |
| `HRMRecorder/Settings.bundle/Root.plist` | New — iOS Settings pane |
| `HRMRecorder/Info.plist` | Add `hrmrecorder://` URL scheme for OAuth redirect |
| `HRMRecorder.xcodeproj/project.pbxproj` | `Settings.bundle` membership exception; version bump |
| `README.md` | Document Server Sync + link `SYNC_PROTOCOL.md` |

## Out of scope

- Real-time per-sample push; background `URLSession`; new background modes.
- Deleting/trimming local data after sync.
- Any server implementation (lives in the server repo).
