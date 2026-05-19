# HRM Recorder

A single-purpose iOS app: connect to a Bluetooth heart-rate strap (Garmin
HRM-Pro+ or any sensor exposing the standard Heart Rate Service `0x180D`),
show live BPM, and record every reading to SQLite in real time. CSV export
included. No activity/GPS recording — heart rate only.

## Run it

1. Open `HRMRecorder.xcodeproj` in Xcode.
2. Select the **HRMRecorder** scheme.
3. **Run on a physical iPhone.** CoreBluetooth does not function in the iOS
   Simulator — the app builds there but will never see the strap.
4. In **Signing & Capabilities**, pick your Apple ID **Team**. With a free
   account, change the bundle identifier (`com.example.HRMRecorder`) to
   something unique, e.g. `com.yourname.hrmrecorder`.

## Using the strap (Garmin HRM-Pro+)

- Moisten the electrodes and wear the strap so it starts advertising.
- The HRM-Pro+ supports **one BLE connection at a time**. Close Garmin
  Connect / disconnect it from other devices first, or this app won't find it.
- First launch shows a Bluetooth permission prompt — allow it.
- The app auto-connects to the first heart-rate strap it sees and remembers
  it. Use **Rescan / Forget device** behavior via the manager if you switch
  straps (`forgetDevice()` clears the saved sensor).

## How it records

- Tap **Start Recording** to open a session; every Heart Rate Measurement
  notification (~1 Hz) is written to SQLite immediately — capture and save
  are both real time. **Stop Recording** closes the session.
- `bluetooth-central` background mode keeps readings flowing while the strap
  stays connected and the screen is off. If the strap drops out, the app
  keeps trying to reconnect and resumes the active session automatically.

## Data

SQLite file: `Application Support/hrm.sqlite3` (path shown at the bottom of
the app, WAL mode for durable real-time writes).

```
sessions(id TEXT pk, started_at REAL, ended_at REAL, device_name TEXT,
         manufacturer TEXT, model TEXT, firmware TEXT, body_location TEXT)
samples (id INTEGER pk, session_id TEXT, ts REAL, bpm INTEGER,
         rr_ms TEXT, contact INTEGER, energy_kj INTEGER, device_id TEXT)
devices (id TEXT pk, name TEXT, manufacturer TEXT, model TEXT,
         firmware TEXT, body_location TEXT, first_seen REAL)
```

- `device_name` — BLE advertised name. `manufacturer` / `model` / `firmware`
  are read from the standard Device Information Service (0x180A);
  `body_location` from Body Sensor Location (0x2A38), e.g. Garmin / HRM-Pro+ /
  Chest. The `sessions` columns record the session's primary strap and may be
  NULL if the strap doesn't expose them.
- `samples.device_id` — the CBPeripheral UUID of the strap that produced that
  reading. A session may span more than one strap (multiple straps recorded at
  once, or a mid-recording swap); each sample is attributed to its source.
  NULL for data recorded before this feature — such rows fall back to the
  session's device columns, so old databases export unchanged.
- `devices` — one row per physical strap, keyed by its BLE UUID and
  accumulated via COALESCE like the session device fields (`first_seen` is the
  first time the strap was registered).
- `ts` — Unix epoch seconds (sub-second precision).
- `rr_ms` — R-R intervals for the packet, milliseconds, **semicolon-joined**
  because one Heart Rate Measurement notification can carry several R-R
  intervals (empty if the strap didn't send them). In the CSV this cell is
  RFC-4180 double-quoted so the embedded `;` stays one cell even when opened
  in a locale that uses `;` as the list separator.
- `contact` — sensor skin-contact status: `1` good, `0` poor, NULL = not
  reported.

### CSV export

**Export All as CSV**, or swipe a session for a per-session CSV. The file
opens in the iOS share sheet (save to Files, AirDrop, email, etc.). Columns:

```
timestamp_iso,unix_seconds,session_id,device_name,manufacturer,model,firmware,body_location,bpm,rr_ms,sensor_contact,energy_kj,device_id,device_strap_name
```

Sensor identity columns are denormalized onto every row so each CSV is
self-describing; text fields are RFC-4180 quoted. `device_name` /
`manufacturer` / `model` / `firmware` / `body_location` resolve from the
per-sample strap (`devices`) when known, falling back to the session
identity otherwise — so the first 12 columns are unchanged and byte-identical
to prior exports for single-strap sessions. `device_id` /
`device_strap_name` are appended (stable column order) and are blank for
pre-feature rows.

## Project layout

```
HRMRecorder/
  HRMRecorderApp.swift   App entry; owns the DB + BLE manager
  ContentView.swift      SwiftUI UI (live BPM, record toggle, sessions, export)
  HeartRateManager.swift CoreBluetooth: scan/connect/parse 0x2A37
  HRDatabase.swift       libsqlite3 wrapper + CSV export
  Info.plist             Bluetooth usage string + bluetooth-central mode
```

No third-party dependencies — uses the system `SQLite3` module and
CoreBluetooth only.
