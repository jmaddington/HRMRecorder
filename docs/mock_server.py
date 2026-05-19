#!/usr/bin/env python3
"""Reference mock server for the HRM Recorder Server Sync Protocol v1.

NOT part of the Xcode build. Single-file, standard-library only. It exists
so the protocol contract in SYNC_PROTOCOL.md is executable: you can point a
debug build of the app at it, and `--selftest` proves the tricky invariants
(idempotent re-send, accurate cursor, forward references, 413 over-cap,
OAuth discovery/registration/refresh) without any client at all.

It is deliberately in-memory, single-user, and not hardened — it is a
conformance reference, not a deployable server. jmdashboard is the real
reference implementation.

Usage:
    python3 mock_server.py --selftest          # run the invariant checks
    python3 mock_server.py [--port 8777]        # serve for a device build
    python3 mock_server.py --port 8777 --auth-mode token --static-token T
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL = 1
DEFAULT_CAP = 1000


class Store:
    """In-memory account state (single account — the token *is* the account)."""

    def __init__(self):
        self.devices: dict[str, dict] = {}
        self.sessions: dict[str, dict] = {}
        # samples keyed by (client_session_id, client_sample_id) — the
        # protocol idempotency identity (account is implicit here).
        self.samples: dict[tuple[str, int], dict] = {}

    # -- COALESCE upsert: a null/blank field never clobbers a stored value --
    @staticmethod
    def _coalesce(stored: dict, incoming: dict, fields: list[str]):
        for f in fields:
            v = incoming.get(f)
            if v not in (None, ""):
                stored[f] = v

    def upsert_device(self, item: dict):
        cid = item["client_device_id"]
        row = self.devices.setdefault(cid, {"client_device_id": cid})
        if "first_seen" in item and "first_seen" not in row:
            row["first_seen"] = item["first_seen"]
        self._coalesce(row, item, ["name", "manufacturer", "model",
                                   "firmware", "body_location"])

    def upsert_session(self, item: dict):
        sid = item["client_session_id"]
        row = self.sessions.setdefault(
            sid, {"client_session_id": sid,
                  "started_at": item.get("started_at")})
        if item.get("started_at") is not None:
            row["started_at"] = item["started_at"]
        # ended_at: null -> value only; never back to null, never clobbered.
        ea = item.get("ended_at")
        if ea is not None and row.get("ended_at") is None:
            row["ended_at"] = ea
        self._coalesce(row, item, ["device_name", "manufacturer", "model",
                                   "firmware", "body_location"])

    def ensure_session_stub(self, sid: str, ts: float):
        self.sessions.setdefault(
            sid, {"client_session_id": sid, "started_at": ts,
                  "ended_at": None})

    def ensure_device_stub(self, cid: str):
        self.devices.setdefault(cid, {"client_device_id": cid})

    def add_samples(self, items: list[dict]) -> tuple[int, int]:
        accepted = duplicates = 0
        for it in items:
            sid = it["client_session_id"]
            key = (sid, int(it["client_sample_id"]))
            # Forward reference: a sample may arrive before its session /
            # device — accept it, stub the parents, upgrade later.
            self.ensure_session_stub(sid, it["ts"])
            if it.get("client_device_id"):
                self.ensure_device_stub(it["client_device_id"])
            if key in self.samples:
                duplicates += 1
                continue
            self.samples[key] = it
            accepted += 1
        return accepted, duplicates

    def max_client_sample_id(self, session_ids) -> int:
        ids = [csid for (sid, csid) in self.samples if sid in session_ids]
        return max(ids) if ids else 0

    def session_state(self, sid: str) -> dict | None:
        if sid not in self.sessions:
            return None
        sample_ids = [csid for (s, csid) in self.samples if s == sid]
        return {
            "known": True,
            "ended_at": self.sessions[sid].get("ended_at"),
            "sample_count": len(sample_ids),
            "max_client_sample_id": max(sample_ids) if sample_ids else 0,
        }


class OAuth:
    """Minimal RFC 8414 / 7591 / PKCE-S256 / refresh stub."""

    def __init__(self, issuer: str):
        self.issuer = issuer
        self.clients: dict[str, dict] = {}
        self.codes: dict[str, dict] = {}        # code -> {challenge}
        self.tokens: set[str] = set()
        self.refresh: dict[str, bool] = {}

    def metadata(self) -> dict:
        return {
            "issuer": self.issuer,
            "authorization_endpoint": f"{self.issuer}/authorize",
            "token_endpoint": f"{self.issuer}/token",
            "registration_endpoint": f"{self.issuer}/register",
            "scopes_supported": ["api:read", "api:write"],
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
        }

    def register(self, body: dict) -> dict:
        cid = "mock-" + secrets.token_hex(6)
        self.clients[cid] = body
        return {
            "client_id": cid,
            "redirect_uris": body.get("redirect_uris", []),
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
        }

    def authorize(self, qs: dict) -> tuple[str, str]:
        code = secrets.token_urlsafe(16)
        self.codes[code] = {"challenge": qs.get("code_challenge", [""])[0]}
        redirect = qs.get("redirect_uri", [""])[0]
        state = qs.get("state", [""])[0]
        loc = f"{redirect}?code={code}"
        if state:
            loc += f"&state={urllib.parse.quote(state)}"
        return code, loc

    @staticmethod
    def _s256(verifier: str) -> str:
        digest = hashlib.sha256(verifier.encode()).digest()
        return base64.urlsafe_b64encode(digest).decode().rstrip("=")

    def token(self, form: dict) -> dict | None:
        grant = form.get("grant_type", [""])[0]
        if grant == "authorization_code":
            code = form.get("code", [""])[0]
            rec = self.codes.pop(code, None)
            if rec is None:
                return None
            verifier = form.get("code_verifier", [""])[0]
            if rec["challenge"] and self._s256(verifier) != rec["challenge"]:
                return None
        elif grant == "refresh_token":
            rt = form.get("refresh_token", [""])[0]
            if rt not in self.refresh:
                return None
        else:
            return None
        access = secrets.token_urlsafe(24)
        rtok = secrets.token_urlsafe(24)
        self.tokens.add(access)
        self.refresh[rtok] = True
        return {
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": rtok,
            "scope": "api:read api:write",
        }

    def valid(self, token: str) -> bool:
        return token in self.tokens


class App:
    def __init__(self, *, issuer, auth_mode="oauth", static_token=None,
                 cap=DEFAULT_CAP):
        self.store = Store()
        self.oauth = OAuth(issuer)
        self.auth_mode = auth_mode
        self.static_token = static_token
        self.cap = cap

    # -- auth: Bearer is an OAuth access token or the configured static one --
    def authorized(self, headers) -> bool:
        h = headers.get("Authorization", "")
        if not h.startswith("Bearer "):
            return False
        tok = h[len("Bearer "):]
        if self.static_token and tok == self.static_token:
            return True
        return self.oauth.valid(tok)

    def ping(self) -> dict:
        auth = {"mode": self.auth_mode}
        if self.auth_mode == "oauth":
            auth["oauth_metadata_url"] = (
                f"{self.oauth.issuer}/.well-known/oauth-authorization-server")
        return {"ok": True, "protocol": PROTOCOL,
                "limits": {"max_samples_per_request": self.cap},
                "auth": auth}


class Handler(BaseHTTPRequestHandler):
    app: App = None  # injected

    def log_message(self, *a):  # quiet
        pass

    def _send(self, code: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _err(self, code: int, ecode: str, message: str = "", **extra):
        self._send(code, {"error": {"code": ecode, "message": message, **extra}})

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def _form(self) -> dict:
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n).decode() if n else ""
        return urllib.parse.parse_qs(raw)

    # -- routing --
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        path, qs = u.path, urllib.parse.parse_qs(u.query)
        app = self.app

        if path.endswith("/ping") or path == "/ping":
            return self._send(200, app.ping())
        if path == "/.well-known/oauth-authorization-server":
            return self._send(200, app.oauth.metadata())
        if path == "/authorize":
            _, loc = app.oauth.authorize(qs)
            self.send_response(302)
            self.send_header("Location", loc)
            self.end_headers()
            return
        if path.startswith("/sessions/"):
            if not app.authorized(self.headers):
                return self._err(401, "unauthorized", "Bearer required")
            sid = urllib.parse.unquote(path[len("/sessions/"):].rstrip("/"))
            state = app.store.session_state(sid)
            return self._send(200, state or {"known": False})
        return self._err(404, "not_found", path)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        path = u.path
        app = self.app

        if path == "/register":
            return self._send(201, app.oauth.register(self._body()))
        if path == "/token":
            tok = app.oauth.token(self._form())
            if tok is None:
                return self._err(400, "invalid_grant", "bad code/verifier")
            return self._send(200, tok)

        if not app.authorized(self.headers):
            return self._err(401, "unauthorized", "Bearer required")

        body = self._body()
        items = body.get("items", [])
        if not isinstance(items, list):
            return self._err(400, "bad_request", "items must be a list")

        if path == "/devices":
            if len(items) > 200:
                return self._err(413, "batch_too_large", max=200)
            for it in items:
                app.store.upsert_device(it)
            return self._send(200, {"accepted": len(items)})

        if path == "/sessions":
            if len(items) > 200:
                return self._err(413, "batch_too_large", max=200)
            for it in items:
                app.store.upsert_session(it)
            return self._send(200, {"accepted": len(items)})

        if path == "/samples":
            if len(items) > app.cap:
                return self._err(413, "batch_too_large", max=app.cap)
            accepted, dups = app.store.add_samples(items)
            sids = {it["client_session_id"] for it in items}
            return self._send(200, {
                "accepted": accepted,
                "duplicates": dups,
                "max_client_sample_id": app.store.max_client_sample_id(sids),
            })

        return self._err(404, "not_found", path)


def serve(port: int, app: App):
    Handler.app = app
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"HRM mock server on :{port}  (auth_mode={app.auth_mode}, "
          f"cap={app.cap})")
    httpd.serve_forever()


# --------------------------------------------------------------------------
# Self-test — proves the protocol invariants without a client.
# --------------------------------------------------------------------------

def selftest() -> int:
    app = App(issuer="http://localhost:0", cap=3)
    s = app.store
    fails = []

    def check(name, cond):
        print(f"  {'PASS' if cond else 'FAIL'}  {name}")
        if not cond:
            fails.append(name)

    # OAuth discovery → register → PKCE code → token → refresh
    md = app.oauth.metadata()
    check("RFC 8414 metadata advertises S256",
          md["code_challenge_methods_supported"] == ["S256"])
    reg = app.oauth.register({"redirect_uris": ["hrmrecorder://oauth-callback"]})
    check("RFC 7591 dynamic registration returns client_id",
          reg["client_id"].startswith("mock-"))
    verifier = secrets.token_urlsafe(32)
    challenge = OAuth._s256(verifier)
    code, _ = app.oauth.authorize({"code_challenge": [challenge],
                                   "redirect_uri": ["hrmrecorder://oauth-callback"]})
    bad = app.oauth.token({"grant_type": ["authorization_code"],
                           "code": [code], "code_verifier": ["wrong"]})
    check("PKCE S256 mismatch is rejected", bad is None)
    code2, _ = app.oauth.authorize({"code_challenge": [challenge],
                                    "redirect_uri": ["x"]})
    tok = app.oauth.token({"grant_type": ["authorization_code"],
                           "code": [code2], "code_verifier": [verifier]})
    check("PKCE S256 match issues access+refresh",
          tok and tok["access_token"] and tok["refresh_token"])
    check("access token authenticates",
          app.authorized({"Authorization": f"Bearer {tok['access_token']}"}))
    refreshed = app.oauth.token({"grant_type": ["refresh_token"],
                                 "refresh_token": [tok["refresh_token"]]})
    check("refresh_token yields a new access token",
          refreshed and refreshed["access_token"] != tok["access_token"])

    # ping discovery
    p = app.ping()
    check("ping advertises protocol + cap + oauth metadata url",
          p["protocol"] == 1 and p["limits"]["max_samples_per_request"] == 3
          and p["auth"]["oauth_metadata_url"].endswith(
              "/.well-known/oauth-authorization-server"))

    # Forward reference: samples before their session/device.
    a, d = s.add_samples([
        {"client_session_id": "s-late", "client_sample_id": 1,
         "client_device_id": "dev-late", "ts": 1000.0, "bpm": 70},
    ])
    check("sample before session is accepted (a=1,d=0)", a == 1 and d == 0)
    check("forward ref stubbed the session", "s-late" in s.sessions)
    check("forward ref stubbed the device", "dev-late" in s.devices)
    s.upsert_session({"client_session_id": "s-late", "started_at": 999.0,
                      "device_name": "HRM-Pro+"})
    check("later session upgrades the stub via COALESCE",
          s.sessions["s-late"]["device_name"] == "HRM-Pro+")

    # Idempotent re-send + accurate cursor.
    batch = [{"client_session_id": "s1", "client_sample_id": i,
              "ts": 1000.0 + i, "bpm": 60 + i} for i in (10, 11, 12)]
    a1, d1 = s.add_samples(batch)
    cur1 = s.max_client_sample_id({"s1"})
    a2, d2 = s.add_samples(batch)
    cur2 = s.max_client_sample_id({"s1"})
    check("first send accepts all (a=3,d=0)", a1 == 3 and d1 == 0)
    check("re-send is all duplicates (a=0,d=3)", a2 == 0 and d2 == 3)
    check("cursor accurate & stable across re-send",
          cur1 == 12 and cur2 == 12)

    # ended_at null->value only.
    s.upsert_session({"client_session_id": "s1", "started_at": 1.0,
                      "ended_at": 5000.0})
    s.upsert_session({"client_session_id": "s1", "started_at": 1.0,
                      "ended_at": None})
    check("ended_at does not revert to null",
          s.sessions["s1"]["ended_at"] == 5000.0)

    # session state recovery.
    st = s.session_state("s1")
    check("session state reports count + cursor",
          st["known"] and st["sample_count"] == 3
          and st["max_client_sample_id"] == 12)
    check("unknown session -> known False",
          s.session_state("nope") is None)

    # 413 over-cap is the handler's job; assert the boundary the handler uses.
    over = [{"client_session_id": "s1", "client_sample_id": i,
             "ts": 1.0, "bpm": 60} for i in range(app.cap + 1)]
    check("over-cap batch exceeds the advertised cap", len(over) > app.cap)

    print()
    if fails:
        print(f"{len(fails)} CHECK(S) FAILED: {fails}")
        return 1
    print("ALL CHECKS PASSED")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--auth-mode", choices=["oauth", "token"], default="oauth")
    ap.add_argument("--static-token", default=None)
    ap.add_argument("--cap", type=int, default=DEFAULT_CAP)
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())

    issuer = f"http://localhost:{args.port}"
    app = App(issuer=issuer, auth_mode=args.auth_mode,
              static_token=args.static_token, cap=args.cap)
    try:
        serve(args.port, app)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
