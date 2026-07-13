# HRM Recorder — Server Sync Protocol v1

**Status:** v1 — implemented and shipping in the app (`SyncUploader` /
`SyncAuth` / `ServerSyncView`). This document remains the normative contract.
**Audience:** Anyone running their own server to receive heart-rate data from
HRM Recorder. This document is the contract. Implement it and the app will
sync to your server with no app changes.

HRM Recorder is a generic, publicly distributed recorder. It is **not** tied
to any one server. The user supplies a base URL and authenticates (OAuth 2.1
where the server offers it, otherwise a static token); the app then pushes
its recorded data using the protocol below. `jmdashboard` is the reference
server implementation, but the protocol is vendor-neutral by design.

---

## 1. Design goals

- **Anyone can implement the server side.** Plain HTTPS + JSON. A minimal
  server only has to check a static Bearer token; richer servers add OAuth.
- **Idempotent and resumable.** The app may re-send anything at any time
  (crash, reinstall, flaky network, server restore-from-backup). Re-sending
  never duplicates or corrupts data.
- **Incremental.** Sessions are long (hours), ~1 sample/second. The app
  sends only what the server has not yet acknowledged.
- **Faithful.** Full local fidelity — every 1 Hz sample, R-R intervals,
  skin-contact, energy, per-strap device attribution — matching the app's
  SQLite schema and CSV export 1:1.
- **Lossless to the client.** A sync never deletes local data; the local
  SQLite DB stays the source of truth.

## 2. Transport & conventions

| Aspect | Value |
|---|---|
| Transport | **HTTPS only.** Plaintext HTTP is rejected by the app, no exceptions. |
| Encoding | `application/json; charset=utf-8`, request and response |
| Base URL | User-configured, the **complete** prefix the operator hands out (e.g. `https://dash.example.com/api/v1/health/hr/`). The app appends only the relative resource segments below — it adds **no** version or path prefix of its own. |
| Protocol version | Sent as `X-HRM-Protocol: 1` request header; echoed by `GET ping`. Not in the path. |
| Timestamps | Unix epoch **seconds**, JSON number, sub-second fractional allowed (matches the app's `ts` storage exactly). |
| Auth | `Authorization: Bearer <token>` on every data request (token is an OAuth 2.1 access token or a static token — see §3). |
| Time skew | Server must not reject on client clock skew; `ts` is the device clock, stored as-is. |

For a configured base `B`, a conformant server exposes:

```
GET   B/ping                              # unauthenticated discovery
POST  B/devices
POST  B/sessions
POST  B/samples
GET   B/sessions/{client_session_id}
```

`ping` is the only unauthenticated endpoint; it carries no user data and
exists so the app can discover reachability, protocol version, batch limits,
and **how to authenticate** before it has a token.

## 3. Authentication

Every data request carries `Authorization: Bearer <token>`. How the app
obtains that token depends on what the server advertises in `GET ping`
(see §5) under `auth`:

### 3.1 OAuth 2.1 (preferred)

If `ping.auth.mode == "oauth"`, the server provides
`auth.oauth_metadata_url` — an absolute URL to RFC 8414 OAuth 2.0
Authorization Server Metadata. The app then performs standard OAuth 2.1:

- RFC 8414 metadata discovery at `oauth_metadata_url`.
- RFC 7591 dynamic client registration (the app is a public client; no
  pre-registration or operator-side app config required).
- Authorization Code + **PKCE (S256)** via an in-app system web auth
  session. A custom redirect scheme (`hrmrecorder://oauth-callback`) returns
  the code.
- Token endpoint exchange → access token + **refresh token**. The refresh
  token is what lets the **background auto-uploader keep working unattended**;
  the user signs in once.
- The access token is sent as `Authorization: Bearer`. On `401`, the app
  refreshes; if refresh fails it surfaces "sign in again" (recording is never
  affected).

This reuses the server's existing OAuth 2.1 authorization server — no
HR-specific OAuth endpoint is required. On `jmdashboard` it is the same
authorization server already used for `/api/v1/` and the MCP surface; the HR
endpoints are ordinary API endpoints that already accept those tokens.
Tokens must carry write access for ingest and read access for the read
endpoints (jmdashboard: `api:write` / `api:read` scopes).

### 3.2 Static Bearer token (fallback)

If `ping.auth.mode == "token"` (or `ping` is unreachable / omits `auth`),
the app uses a static opaque token the user pastes into Settings, issued
out-of-band from the server's own settings UI. This keeps the minimum
server bar low: a DIY server that only checks a shared secret is fully
conformant.

The token (OAuth or static) is opaque to the app and is stored in the iOS
**Keychain**, never in plist-backed preferences.

## 4. Identifiers

| Name | Type | Origin | Stability |
|---|---|---|---|
| `client_session_id` | string (≤ 64) | App `sessions.id`, e.g. `20260519T143012Z-a3f` | Stable forever for that recording |
| `client_sample_id` | int64 | App `samples.id` (SQLite `AUTOINCREMENT`) | Strictly increasing per install; the sync cursor |
| `client_device_id` | string (≤ 64) | Strap `CBPeripheral` UUID | Stable per physical strap per install |

All three are client-generated. The server treats them as opaque natural
keys scoped to the authenticated account, assigns its own primary keys, and
must never require the client to know server-side keys. There are no account
identifiers on the wire — the token *is* the account.

## 5. Endpoints

Batch-shaped (`{"items":[...]}`) so one endpoint serves one or many. All
writes are idempotent.

### `GET ping` — unauthenticated discovery

```json
{
  "ok": true,
  "protocol": 1,
  "limits": { "max_samples_per_request": 1000 },
  "auth": {
    "mode": "oauth",
    "oauth_metadata_url": "https://dash.example.com/.well-known/oauth-authorization-server"
  }
}
```

`auth.mode` is `"oauth"` or `"token"`. For `"token"`, `oauth_metadata_url`
is omitted. The app's "Test connection" button calls this, then (if it has
a token) an authenticated probe.

### `POST devices`
Upsert device identities. `{"items":[Device,...]}` (≤ 200).
`200 {"accepted": n}`. COALESCE semantics: a `null`/blank field must not
overwrite a stored non-null value.

### `POST sessions`
Upsert sessions. `{"items":[Session,...]}` (≤ 200). `200 {"accepted": n}`.
`ended_at` may transition `null`→value (session closed) but never back.

### `POST samples`
Append samples. `{"items":[Sample,...]}` (≤ `max_samples_per_request`).
Dedupe on `(account, client_session_id, client_sample_id)`; ignore
duplicates silently (never `409`). Samples whose session/device rows have
not arrived yet are still accepted.

```json
{ "accepted": 1000, "duplicates": 0, "max_client_sample_id": 84211 }
```

`max_client_sample_id` = largest id durably stored for this account across
the request's sessions — the app's cursor. Over-cap ⇒ `413
{"error":{"code":"batch_too_large","max":N}}`.

### `GET sessions/{client_session_id}`
Cursor/state recovery (after reinstall or server restore).

```json
{ "known": true, "ended_at": 1747668000.0, "sample_count": 6588, "max_client_sample_id": 84211 }
```

`known:false` (HTTP 200) when absent.

## 6. Resources

Field nullability matches the app's SQLite schema (`null` where the strap
did not report a value).

**Device** — `client_device_id`, `name?`, `manufacturer?`, `model?`,
`firmware?`, `body_location?`, `first_seen` (epoch).

**Session** — `client_session_id`, `started_at` (epoch), `ended_at?`
(epoch; null while recording), `device_name?`, `manufacturer?`, `model?`,
`firmware?`, `body_location?`.

**Sample** — `client_session_id`, `client_sample_id` (int64),
`client_device_id?`, `ts` (epoch, sub-second), `bpm` (int), `rr_ms?`
(semicolon-joined ms, verbatim e.g. `"812;806"`), `contact?` (1 good / 0
poor / null), `energy_kj?` (int).

## 7. Batching & limits

- Default sample batch ceiling **1000**; a server may lower it via
  `ping.limits.max_samples_per_request`; the app honors it.
- Over-cap body ⇒ `413` `{"error":{"code":"batch_too_large","max":N}}`; the
  app halves and retries.
- The app sends batches in ascending `client_sample_id` and advances its
  cursor only after a `2xx`.

## 8. Idempotency & incremental sync (client algorithm)

The app keeps one integer **cursor** = highest acked `client_sample_id`.

```
on trigger (session end, app foreground/background, retry timer):
  ensure valid token (OAuth refresh if needed) — else surface, stop
  POST devices   { changed devices }
  POST sessions  { sessions touched since last sync }
  loop:
    batch = local samples WHERE id > cursor ORDER BY id LIMIT N
    if empty: break
    resp = POST samples { batch }
    cursor = max(cursor, resp.max_client_sample_id)
  persist cursor
```

**Cursor repair** (reinstall, lost local state, server restored old backup):
`GET sessions/{id}` and set `cursor = min(local, server.max_client_sample_id)`
so anything the server lacks is re-sent. Idempotent ⇒ over-sending is safe.

## 9. Errors

JSON error body on non-2xx: `{"error":{"code":"...","message":"..."}}`.

| HTTP | Meaning | App behavior |
|---|---|---|
| 200 | OK | Advance cursor |
| 400 | Malformed | Surface; don't blind-retry |
| 401 | Token expired/invalid | OAuth: refresh then retry. Static: surface "check token" |
| 403 | Insufficient scope | Surface "re-authorize" |
| 404 | Wrong base URL / route | Surface "check server URL" |
| 413 | Batch too large | Halve, retry |
| 429 | Rate limited | Honor `Retry-After`, back off |
| 5xx | Server error | Exponential backoff |

A sync failure never affects recording and never deletes local data.

## 10. Security

- HTTPS only; the app refuses non-HTTPS base URLs outright.
- Tokens (OAuth access/refresh or static) live in the iOS Keychain, sent
  only over TLS.
- OAuth: public client, PKCE S256, exact redirect-URI match, short-lived
  access token + rotating refresh token recommended.
- The server scopes all data to the token's account and trusts no
  client-supplied account identifier (there are none).

## 11. Minimum conformance checklist

A conformant server MUST:

1. Serve `GET ping` unauthenticated with `protocol`, `limits`, and `auth`.
2. Authenticate every data request via `Authorization: Bearer`.
3. Either advertise OAuth 2.1 (RFC 8414 metadata + 7591 + PKCE) **or**
   accept a static Bearer token — at least one.
4. Implement `devices`, `sessions`, `samples`, `sessions/{id}`.
5. Treat `(account, client_session_id, client_sample_id)` as the sample
   identity; ignore duplicates without error.
6. Apply COALESCE (non-null-wins) upsert to device/session identity fields.
7. Return an accurate `max_client_sample_id`; accept samples whose
   session/device rows have not arrived yet; never require server-side keys.

## 12. Reference implementation

`jmdashboard` implements this by serving the endpoints under its existing
health API and reusing its existing OAuth 2.1 authorization server (the same
one already used for `/api/v1/` and MCP) — no HR-specific auth endpoint. A
static personal API key is accepted as the §3.2 fallback. See, in that repo:
`docs/superpowers/specs/2026-05-19-heart-rate-ingest-design.md` and
`docs/openapi/openapi-heart-rate-ingest-design.yaml`.
