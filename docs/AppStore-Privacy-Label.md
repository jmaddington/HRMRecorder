# App Store Connect — App Privacy answers (HRM Recorder)

Fill these in at: App Store Connect → HRM Recorder → **App Privacy** → Edit.
This mirrors `HRMRecorder/PrivacyInfo.xcprivacy`. Keep the two consistent.

## Top-level question
**"Do you or your third-party partners collect data from this app?"**
→ **No, we do not collect data from this app.**

### Why this is the correct answer
Apple defines "collect" as transmitting data **off the device** in a way the
**developer** can access. For HRM Recorder:

- **Heart-rate samples / sessions** — written only to the on-device SQLite DB
  (`Application Support/hrm.sqlite3`). Never sent to the developer.
- **CSV export** — the *user* shares a file via the iOS share sheet to a
  destination they choose. Not transmitted to the developer.
- **Server Sync (optional, off by default)** — uploads to a server the **user**
  configures and hosts. This is the user's own endpoint, not a developer- or
  third-party-controlled server, so it is NOT "data collection" by the
  developer under Apple's definition. (OAuth tokens for that server are stored
  in the device Keychain, never transmitted to the developer.)
- **No analytics / advertising / crash SDKs.** No third-party data collection.
- **No account, no login** for core use.

> If a reviewer pushes back on the optional sync: it is user-operated data
> portability to the user's own server, comparable to "export to my own
> WebDAV". The developer receives nothing. If Apple insists it be declared,
> the category would be **Health & Fitness → Health**, purpose **App
> Functionality**, **not** linked to identity, **not** used for tracking — but
> "Data Not Collected" is the accurate first answer.

## Tracking
**"Does this app track users?"** (ATT / cross-app-and-website tracking)
→ **No.** Matches `NSPrivacyTracking = false` and empty `NSPrivacyTrackingDomains`.

## Result
With "we do not collect data," App Store Connect shows the **"Data Not
Collected"** privacy label and no further data-type screens are required.

---

## Related one-time TestFlight fields (Test Information)
- **Sign-in required?** → **No** (core record/export needs no account).
- **Export Compliance / Encryption** → **No** (uses only exempt/standard
  encryption; matches `ITSAppUsesNonExemptEncryption = false` in Info.plist).
- **Beta App Description / Feedback email** → required once for external testing.
