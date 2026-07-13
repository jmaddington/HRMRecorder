#!/usr/bin/env python3
"""Minimal self-hosted receiver for the HRM Recorder Server Sync Protocol v1.

A complete, runnable example of the *smallest* conformant server: one file,
Flask + SQLite, static Bearer token auth. Point the app's "Server Sync"
settings at it and your phone will push every recorded heartbeat here.

    export HRM_TOKEN="pick-a-long-random-string"
    python hrm_receiver.py                # or: flask --app hrm_receiver run

Protocol contract: docs/SYNC_PROTOCOL.md in the HRM Recorder repo
(https://github.com/jmaddington/HRMRecorder). The stdlib mock server in the
same repo (docs/mock_server.py, `--selftest`) is the conformance reference.

IMPORTANT — this is a starting point for handling YOUR OWN data on YOUR OWN
server, not hardened production code. At minimum, run it behind a reverse
proxy that terminates TLS (Caddy, nginx + certbot): the app refuses plain
http:// base URLs outright, so HTTPS in front is not optional.
"""

import hmac
import os
import sqlite3

from flask import Flask, g, jsonify, request

# --- Configuration (environment variables) --------------------------------
# The static Bearer token the app will send. The token *is* the account:
# there are no user identifiers on the wire, so keep it long and random.
TOKEN = os.environ.get("HRM_TOKEN")
if not TOKEN:
    raise SystemExit("Set HRM_TOKEN before starting (any long random string).")

DB_PATH = os.environ.get("HRM_DB", "hrm_sync.sqlite3")

# Advertised in `ping`; the app never sends a bigger samples batch, and we
# answer 413 if a misbehaving client does anyway (protocol section 7).
MAX_SAMPLES = int(os.environ.get("HRM_MAX_SAMPLES", "1000"))
MAX_META = 200  # cap for devices/sessions batches, per the spec

app = Flask(__name__)

# --- Storage ---------------------------------------------------------------
# Mirrors the app's own schema (see the repo README). All ids below are
# CLIENT-generated natural keys; a conformant server never asks the app to
# know server-side keys. Timestamps are Unix epoch seconds (REAL, sub-second
# precision preserved).
SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
  client_device_id TEXT PRIMARY KEY,   -- strap's BLE UUID, stable per install
  name TEXT, manufacturer TEXT, model TEXT, firmware TEXT,
  body_location TEXT,
  first_seen REAL
);
CREATE TABLE IF NOT EXISTS sessions (
  client_session_id TEXT PRIMARY KEY,  -- e.g. 20260519T143012Z-a3f
  started_at REAL,
  ended_at REAL,                       -- NULL while still recording
  device_name TEXT, manufacturer TEXT, model TEXT, firmware TEXT,
  body_location TEXT
);
CREATE TABLE IF NOT EXISTS samples (
  client_session_id TEXT NOT NULL,
  client_sample_id INTEGER NOT NULL,   -- strictly increasing; the sync cursor
  client_device_id TEXT,               -- which strap produced this reading
  ts REAL NOT NULL,
  bpm INTEGER NOT NULL,
  rr_ms TEXT,                          -- semicolon-joined ms, e.g. "812;806"
  contact INTEGER,                     -- 1 good / 0 poor / NULL not reported
  energy_kj INTEGER,
  -- The protocol's idempotency identity: (account, session, sample id).
  -- The account is implicit (the token), so this PK is the whole dedupe.
  PRIMARY KEY (client_session_id, client_sample_id)
);
"""


def db() -> sqlite3.Connection:
    """One SQLite connection per request, created lazily, closed by Flask."""
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
        g.db.executescript(SCHEMA)
    return g.db


@app.teardown_appcontext
def _close_db(_exc):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


# --- Helpers ----------------------------------------------------------------
def norm(value):
    """Treat blank strings as null: the COALESCE upsert rule says a null OR
    blank field must never overwrite a stored non-null value."""
    return None if value in (None, "") else value


def err(status: int, code: str, message: str = "", **extra):
    """Protocol error shape: {"error":{"code":...,"message":...}} on non-2xx."""
    return jsonify({"error": {"code": code, "message": message, **extra}}), status


def get_items(max_items: int):
    """Parse and bounds-check a batch body {"items":[...]}.
    Returns (items, None) or (None, error_response)."""
    body = request.get_json(silent=True)
    if body is None or not isinstance(body.get("items"), list):
        return None, err(400, "bad_request", "body must be {\"items\": [...]}")
    items = body["items"]
    if len(items) > max_items:
        # Over-cap contract (section 7): the app halves the batch and retries,
        # so `max` must be the real ceiling, not a suggestion.
        return None, err(413, "batch_too_large", max=max_items)
    return items, None


# --- Auth --------------------------------------------------------------------
@app.before_request
def check_auth():
    # `ping` is the ONLY unauthenticated endpoint (discovery: the app must be
    # able to learn how to authenticate before it has a token).
    if request.path.rstrip("/").endswith("/ping") and request.method == "GET":
        return None
    header = request.headers.get("Authorization", "")
    supplied = header[len("Bearer "):] if header.startswith("Bearer ") else ""
    # AIDEV-NOTE: compare_digest, not ==, to avoid a timing side-channel.
    if not hmac.compare_digest(supplied.encode(), TOKEN.encode()):
        return err(401, "unauthorized", "Bearer token required")
    return None


# --- Endpoints ----------------------------------------------------------------
@app.get("/ping")
def ping():
    """Unauthenticated discovery: protocol version, batch limits, auth mode.
    "token" tells the app to use the static token pasted into its Settings."""
    return jsonify({
        "ok": True,
        "protocol": 1,
        "limits": {"max_samples_per_request": MAX_SAMPLES},
        "auth": {"mode": "token"},
    })


@app.post("/devices")
def post_devices():
    """Upsert strap identities. COALESCE semantics: device info arrives
    asynchronously on the phone (manufacturer/model/firmware are separate BLE
    reads), so partial rows trickle in — later non-null fields fill gaps, and
    a null/blank never clobbers a value we already stored."""
    items, error = get_items(MAX_META)
    if error:
        return error
    conn = db()
    try:
        for it in items:
            conn.execute(
                """INSERT INTO devices (client_device_id, name, manufacturer,
                                        model, firmware, body_location, first_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(client_device_id) DO UPDATE SET
                     name          = COALESCE(excluded.name, name),
                     manufacturer  = COALESCE(excluded.manufacturer, manufacturer),
                     model         = COALESCE(excluded.model, model),
                     firmware      = COALESCE(excluded.firmware, firmware),
                     body_location = COALESCE(excluded.body_location, body_location),
                     -- first_seen is historical fact: first write wins.
                     first_seen    = COALESCE(first_seen, excluded.first_seen)""",
                (it["client_device_id"], norm(it.get("name")),
                 norm(it.get("manufacturer")), norm(it.get("model")),
                 norm(it.get("firmware")), norm(it.get("body_location")),
                 it.get("first_seen")))
    except (KeyError, TypeError):
        return err(400, "bad_request", "device items need client_device_id")
    conn.commit()
    return jsonify({"accepted": len(items)})


@app.post("/sessions")
def post_sessions():
    """Upsert sessions. Two rules beyond plain COALESCE:
    - started_at: an incoming non-null value wins (it is authoritative).
    - ended_at: may go null -> value exactly once (the session closed) and
      never transitions back — a re-send of an old "still recording" snapshot
      must not reopen a closed session."""
    items, error = get_items(MAX_META)
    if error:
        return error
    conn = db()
    try:
        for it in items:
            conn.execute(
                """INSERT INTO sessions (client_session_id, started_at, ended_at,
                                         device_name, manufacturer, model,
                                         firmware, body_location)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(client_session_id) DO UPDATE SET
                     started_at    = COALESCE(excluded.started_at, started_at),
                     ended_at      = COALESCE(ended_at, excluded.ended_at),
                     device_name   = COALESCE(excluded.device_name, device_name),
                     manufacturer  = COALESCE(excluded.manufacturer, manufacturer),
                     model         = COALESCE(excluded.model, model),
                     firmware      = COALESCE(excluded.firmware, firmware),
                     body_location = COALESCE(excluded.body_location, body_location)""",
                (it["client_session_id"], it.get("started_at"),
                 it.get("ended_at"), norm(it.get("device_name")),
                 norm(it.get("manufacturer")), norm(it.get("model")),
                 norm(it.get("firmware")), norm(it.get("body_location"))))
    except (KeyError, TypeError):
        return err(400, "bad_request", "session items need client_session_id")
    conn.commit()
    return jsonify({"accepted": len(items)})


@app.post("/samples")
def post_samples():
    """Append heart-rate samples. The three invariants that matter:
    1. Dedupe on (client_session_id, client_sample_id); duplicates are
       IGNORED SILENTLY (never a 409) — the app re-sends freely after
       crashes/reinstalls and counts on idempotency.
    2. Forward references are fine: a sample may arrive before its session
       or device row. Accept it and stub the parents; later upserts upgrade
       the stubs via COALESCE.
    3. max_client_sample_id is the app's cursor. Report the largest id
       DURABLY STORED across this request's sessions — never echo the batch,
       never guess."""
    items, error = get_items(MAX_SAMPLES)
    if error:
        return error
    conn = db()
    accepted = duplicates = 0
    session_ids = set()
    try:
        for it in items:
            sid = it["client_session_id"]
            session_ids.add(sid)
            # Stub parents so foreign data is never rejected for arriving
            # out of order (INSERT OR IGNORE: no-op if the row exists).
            conn.execute(
                "INSERT OR IGNORE INTO sessions (client_session_id, started_at)"
                " VALUES (?, ?)", (sid, it["ts"]))
            if norm(it.get("client_device_id")):
                conn.execute(
                    "INSERT OR IGNORE INTO devices (client_device_id) VALUES (?)",
                    (it["client_device_id"],))
            cur = conn.execute(
                """INSERT OR IGNORE INTO samples
                     (client_session_id, client_sample_id, client_device_id,
                      ts, bpm, rr_ms, contact, energy_kj)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (sid, int(it["client_sample_id"]),
                 norm(it.get("client_device_id")), it["ts"], int(it["bpm"]),
                 norm(it.get("rr_ms")), it.get("contact"),
                 it.get("energy_kj")))
            if cur.rowcount == 1:
                accepted += 1
            else:
                duplicates += 1
    except (KeyError, TypeError, ValueError):
        conn.rollback()
        return err(400, "bad_request",
                   "samples need client_session_id, client_sample_id, ts, bpm")
    conn.commit()  # commit BEFORE reporting the cursor: "durably stored"
    row = conn.execute(
        "SELECT MAX(client_sample_id) AS m FROM samples"
        " WHERE client_session_id IN ({})".format(
            ",".join("?" * len(session_ids))),
        tuple(session_ids)).fetchone() if session_ids else None
    return jsonify({
        "accepted": accepted,
        "duplicates": duplicates,
        "max_client_sample_id": (row["m"] if row and row["m"] is not None else 0),
    })


@app.get("/sessions/<client_session_id>")
def get_session(client_session_id):
    """Cursor/state recovery after a reinstall or a server restore-from-backup.
    An UNKNOWN session is {"known": false} with HTTP 200 — it is a normal
    answer, not an error (404 means "wrong base URL" to the app)."""
    conn = db()
    sess = conn.execute(
        "SELECT ended_at FROM sessions WHERE client_session_id = ?",
        (client_session_id,)).fetchone()
    if sess is None:
        return jsonify({"known": False})
    stats = conn.execute(
        "SELECT COUNT(*) AS n, MAX(client_sample_id) AS m FROM samples"
        " WHERE client_session_id = ?", (client_session_id,)).fetchone()
    return jsonify({
        "known": True,
        "ended_at": sess["ended_at"],
        "sample_count": stats["n"],
        "max_client_sample_id": stats["m"] if stats["m"] is not None else 0,
    })


if __name__ == "__main__":
    # Local testing only. In deployment, run under a WSGI server (gunicorn,
    # waitress) behind a TLS-terminating reverse proxy.
    app.run(host="127.0.0.1", port=8000)
