import Foundation

/// The sync engine — SYNC_PROTOCOL §8.
///
/// Best-effort, opportunistic, cancellable. One default `URLSession` (not a
/// background session — minimal footprint, this is the last app you'd kill).
/// Triggered off the *cold* paths (`stopRecording`, scene background/active, a
/// backoff retry, manual) and once every ~1000 captured samples. The sample
/// trigger fires from `ingest()` but only on every 1000th sample (~16 min at
/// 1 Hz) and `trigger()` is non-blocking, so the ~1 Hz hot path stays clear.
///
/// Hard invariant (CLAUDE.md): every network/HTTP/auth error is caught and
/// recorded in `SyncSettings.lastResult`; recording, the SQLite DB and the
/// live UI are never affected and **no local data is ever deleted by a sync**.
final class SyncUploader: ObservableObject {

    @Published private(set) var status: String

    private let db: HRDatabase
    private let auth: SyncAuth
    private let net: URLSession

    /// Serializes the in-flight flags; the sync itself runs in a Task so the
    /// trigger callers (main thread on stop, scene phase, timer) never block.
    private let gate = DispatchQueue(label: "com.hrmrecorder.sync.gate")
    private var running = false
    private var pending = false
    private var pendingFull = false   // a user-requested full resync is queued
    private var backoff: TimeInterval = 0

    private enum SyncError: Error { case unauthorized, transient, configChanged }

    init(db: HRDatabase, auth: SyncAuth) {
        self.db = db
        self.auth = auth
        self.status = SyncSettings.lastResult
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        self.net = URLSession(configuration: cfg)
    }

    // MARK: - Trigger (coalescing; one sync at a time)

    /// Ask for a sync. If one is already running the request is coalesced
    /// into a single follow-up pass. No-op unless enabled.
    func trigger(_ reason: String) {
        guard SyncSettings.isEnabled else { return }
        gate.async {
            if self.running { self.pending = true; return }
            self.running = true
            Task { await self.runOnce(reason: reason) }
        }
    }

    /// User-initiated **full re-push** (SYNC_PROTOCOL §8 manual cursor repair).
    /// Re-uploads every local sample, ignoring the saved cursor, so the server
    /// backfills anything it is missing. Server ingest is idempotent on
    /// `(account, client_session_id, client_sample_id)`, so already-stored
    /// samples are dropped silently — this only costs bandwidth/CPU, never
    /// duplicates. Coalesces behind an in-flight pass and takes priority over a
    /// queued normal sync (a full pass is a superset of an incremental one).
    func forceResync() {
        guard SyncSettings.isEnabled else { return }
        gate.async {
            if self.running { self.pendingFull = true; return }
            self.running = true
            Task { await self.runFullResync() }
        }
    }

    private func finish() {
        gate.async {
            self.running = false
            if self.pendingFull {
                self.pendingFull = false
                self.pending = false
                self.running = true
                Task { await self.runFullResync() }
            } else if self.pending {
                self.pending = false
                self.running = true
                Task { await self.runOnce(reason: "coalesced") }
            }
        }
    }

    // MARK: - One sync pass (the protocol algorithm)

    private func runOnce(reason: String) async {
        defer { finish() }

        guard SyncSettings.isEnabled, SyncSettings.validatedBaseURL != nil else {
            setStatus("Not configured"); return
        }
        guard let bearer = await auth.currentBearer() else {
            setStatus("Sign in to enable sync"); return
        }
        let cap = max(1, await auth.discover()?.maxSamplesPerRequest ?? 1000)

        do {
            try await post("devices",
                           ["items": db.devicesForUpload().map(Self.encodeDevice)],
                           bearer: bearer)
            try await post("sessions",
                           ["items": db.sessionsForUpload().map(Self.encodeSession)],
                           bearer: bearer)
            try await repairCursorIfNeeded(bearer: bearer)

            var cursor = SyncSettings.cursorSampleID
            var limit = cap
            while true {
                let batch = db.samplesForUpload(afterID: cursor, limit: limit)
                if batch.isEmpty { break }
                let (code, data) = try await postRaw(
                    "samples",
                    ["items": batch.map(Self.encodeSample)],
                    bearer: bearer)
                if code == 200 {
                    // AIDEV-NOTE: HRMRecorder-59s — advance by the LOCAL batch
                    // tail, NEVER by resp.max_client_sample_id. The server
                    // reports the highest id it holds across the batch's
                    // *sessions*, which a second install writing the same
                    // client_session_id can push far beyond our own tail;
                    // trusting it leapfrogs local samples that then never
                    // re-send, and once it passes the local tail every later
                    // pass finds an empty batch and reports "Synced" having
                    // moved nothing. We just sent everything up to this id and
                    // got a 2xx, so it is exactly what we can prove is acked —
                    // the same reasoning runFullResync uses (SYNC_PROTOCOL §8).
                    cursor = max(cursor, batch.last!.clientSampleID)
                    SyncSettings.cursorSampleID = cursor
                    limit = cap                          // reset after success
                } else if code == 413 {
                    // Honor a server cap lower than ours; halve and retry the
                    // same window (cursor not advanced).
                    let advertised = (try? JSONDecoder().decode(
                        BatchTooLarge.self, from: data))?.error.max
                    limit = max(1, min(advertised ?? limit, batch.count) / 2)
                } else if code == 401 {
                    throw SyncError.unauthorized
                } else {
                    throw SyncError.transient
                }
            }
            backoff = 0
            setStatus("Synced \(Self.stamp())")
        } catch SyncError.unauthorized {
            setStatus("Sign in again \(Self.stamp())")
        } catch {
            setStatus("Will retry \(Self.stamp())")
            scheduleBackoff()
        }
    }

    /// SYNC_PROTOCOL §8 cursor repair: after reinstall / a server restored
    /// from an old backup the client cursor may be ahead of the server.
    /// Pull it back to what the server actually has so the gap re-sends
    /// (idempotent — over-sending is safe).
    ///
    /// AIDEV-NOTE: two hard-won rules live here; both cost real user data.
    /// 1. HRMRecorder-59s — the cursor can never legitimately exceed the
    ///    highest id this install has ALLOCATED. A larger value means another
    ///    writer's ids reached our cursor (a second install resuming the same
    ///    session id — HRMRecorder-c74) and silently wedges sync forever.
    ///    Clamp first, unconditionally, before trusting the cursor at all.
    /// 2. HRMRecorder-abr — probe the session that OWNS the cursor, never
    ///    simply the newest session. The newest session is normally the one
    ///    recording right now, with nothing on the server yet, so its
    ///    max_client_sample_id is 0 and a naive `serverMax < cursor` test
    ///    rewinds to 0 every pass — a full re-walk of the entire history.
    private func repairCursorIfNeeded(bearer: String) async throws {
        // Rule 1 — clamp to what this install has actually issued.
        let allocated = db.highestAllocatedSampleID()
        if SyncSettings.cursorSampleID > allocated {
            NSLog("[HRM] Cursor %d exceeded allocated id %d — clamped [HRM-CURSOR-CLAMP]",
                  SyncSettings.cursorSampleID, allocated)
            SyncSettings.cursorSampleID = allocated
        }
        let cursor = SyncSettings.cursorSampleID

        // Rule 2 — probe the cursor's own session. If our cursor means
        // anything, that is the session the server must already know.
        guard cursor > 0,
              let owning = db.sessionID(forSampleAtOrBefore: cursor) else { return }
        let id = owning.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? owning
        let (code, data) = try await getRaw("sessions/\(id)", bearer: bearer)
        guard code == 200,
              let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else { return }
        if state.known != true || (state.sampleCount ?? 0) == 0 {
            // The server has no trace of the session our cursor sits in — a
            // restore from an older backup, or a different account. Nothing
            // at or below the cursor can be trusted; re-offer everything.
            SyncSettings.cursorSampleID = 0
        } else if let serverMax = state.maxClientSampleID, serverMax < cursor {
            SyncSettings.cursorSampleID = serverMax
        }
    }

    /// SYNC_PROTOCOL §8 manual full resync. Unlike `runOnce`, this walks the
    /// LOCAL sample table from the start by `samples.id` and advances the walk
    /// by the last id in each page — never by the server's
    /// `max_client_sample_id`. That distinction is the whole point: the server
    /// cursor reports the highest id it already holds for the batch's sessions,
    /// so advancing by it would leapfrog past interior samples the server is
    /// actually missing and the gap would never be refilled. Over-sending is
    /// safe (idempotent), so we simply offer every local sample exactly once.
    private func runFullResync() async {
        defer { finish() }

        guard SyncSettings.isEnabled, SyncSettings.validatedBaseURL != nil else {
            setStatus("Not configured"); return
        }
        guard let bearer = await auth.currentBearer() else {
            setStatus("Sign in to enable sync"); return
        }
        let cap = max(1, await auth.discover()?.maxSamplesPerRequest ?? 1000)

        do {
            try await post("devices",
                           ["items": db.devicesForUpload().map(Self.encodeDevice)],
                           bearer: bearer)
            try await post("sessions",
                           ["items": db.sessionsForUpload().map(Self.encodeSession)],
                           bearer: bearer)

            var afterID = 0
            var limit = cap
            var resent = 0
            while true {
                let batch = db.samplesForUpload(afterID: afterID, limit: limit)
                if batch.isEmpty { break }
                let (code, data) = try await postRaw(
                    "samples",
                    ["items": batch.map(Self.encodeSample)],
                    bearer: bearer)
                if code == 200 {
                    // Advance by the LOCAL walk so every sample is offered once,
                    // regardless of what the server already holds.
                    afterID = batch.last!.clientSampleID
                    resent += batch.count
                    limit = cap
                    setStatus("Re-uploading… \(resent) sent")
                } else if code == 413 {
                    let advertised = (try? JSONDecoder().decode(
                        BatchTooLarge.self, from: data))?.error.max
                    limit = max(1, min(advertised ?? limit, batch.count) / 2)
                } else if code == 401 {
                    throw SyncError.unauthorized
                } else {
                    throw SyncError.transient
                }
            }
            // AIDEV-NOTE: HRMRecorder-uwa — settle at the local tail
            // UNCONDITIONALLY. A max() here would preserve a cursor parked
            // ABOVE the tail, which is the single case this repair exists to
            // fix; "never move backwards" is the wrong instinct when the
            // current value was never valid. Only reached on a completed walk
            // (the catch path returns early), so by here every local sample
            // has been offered and acked — the tail is precisely correct.
            SyncSettings.cursorSampleID = afterID
            backoff = 0
            setStatus("Full resync done \(Self.stamp()) — \(resent) samples")
        } catch SyncError.unauthorized {
            setStatus("Sign in again \(Self.stamp())")
        } catch {
            setStatus("Resync interrupted \(Self.stamp()) — will retry")
            scheduleBackoff()
        }
    }

    // MARK: - HTTP (one 401-triggered refresh + retry, then give up)

    private func post(_ path: String, _ body: [String: Any],
                      bearer: String) async throws {
        let (code, _) = try await postRaw(path, body, bearer: bearer)
        if code == 401 { throw SyncError.unauthorized }
        guard (200...299).contains(code) else { throw SyncError.transient }
    }

    private func postRaw(_ path: String, _ body: [String: Any],
                         bearer: String) async throws -> (Int, Data) {
        try await sendRaw(path, method: "POST", body: body, bearer: bearer)
    }

    private func getRaw(_ path: String, bearer: String) async throws -> (Int, Data) {
        try await sendRaw(path, method: "GET", body: nil, bearer: bearer)
    }

    private func sendRaw(_ path: String, method: String, body: [String: Any]?,
                         bearer: String) async throws -> (Int, Data) {
        guard let url = SyncSettings.resourceURL(path) else {
            throw SyncError.configChanged
        }
        func build(_ token: String) throws -> URLRequest {
            var r = URLRequest(url: url)
            r.httpMethod = method
            r.setValue("1", forHTTPHeaderField: "X-HRM-Protocol")
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                r.setValue("application/json; charset=utf-8",
                           forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            return r
        }
        let (data, resp) = try await net.data(for: try build(bearer))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Single silent reauth: refresh via SyncAuth, retry once.
        if code == 401, let fresh = await auth.currentBearer(), fresh != bearer {
            let (d2, r2) = try await net.data(for: try build(fresh))
            return ((r2 as? HTTPURLResponse)?.statusCode ?? 0, d2)
        }
        return (code, data)
    }

    // MARK: - Wire encoders (protocol §6; explicit null where strap silent)

    private static func nz(_ s: String?) -> Any { (s?.isEmpty == false) ? s! : NSNull() }

    private static func encodeDevice(_ d: HRDatabase.DeviceRow) -> [String: Any] {
        ["client_device_id": d.clientDeviceID,
         "name": nz(d.name), "manufacturer": nz(d.manufacturer),
         "model": nz(d.model), "firmware": nz(d.firmware),
         "body_location": nz(d.bodyLocation), "first_seen": d.firstSeen]
    }

    private static func encodeSession(_ s: HRDatabase.SessionRow) -> [String: Any] {
        ["client_session_id": s.clientSessionID,
         "started_at": s.startedAt,
         "ended_at": s.endedAt.map { $0 as Any } ?? NSNull(),
         "device_name": nz(s.deviceName), "manufacturer": nz(s.manufacturer),
         "model": nz(s.model), "firmware": nz(s.firmware),
         "body_location": nz(s.bodyLocation)]
    }

    private static func encodeSample(_ s: HRDatabase.SampleRow) -> [String: Any] {
        ["client_session_id": s.clientSessionID,
         "client_sample_id": s.clientSampleID,
         "client_device_id": nz(s.clientDeviceID),
         "ts": s.ts, "bpm": s.bpm,
         "rr_ms": nz(s.rrMs),
         "contact": s.contact.map { $0 as Any } ?? NSNull(),
         "energy_kj": s.energyKJ.map { $0 as Any } ?? NSNull()]
    }

    // MARK: - Status / backoff

    private func setStatus(_ s: String) {
        SyncSettings.lastResult = s
        DispatchQueue.main.async { self.status = s }
    }

    private func scheduleBackoff() {
        guard SyncSettings.isEnabled else { return }
        backoff = backoff == 0 ? 30 : min(backoff * 2, 600)
        let delay = backoff
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.trigger("backoff")
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

// Decoders for the engine's own bookkeeping.
// AIDEV-NOTE: there is deliberately no decoder for the POST samples response.
// Its `max_client_sample_id` must NOT drive the cursor (HRMRecorder-59s) —
// the upload loop advances by the local batch tail instead.
private struct SessionState: Decodable {
    let known: Bool?
    let sampleCount: Int?
    let maxClientSampleID: Int?
    enum CodingKeys: String, CodingKey {
        case known
        case sampleCount = "sample_count"
        case maxClientSampleID = "max_client_sample_id"
    }
}

private struct BatchTooLarge: Decodable {
    struct E: Decodable { let max: Int? }
    let error: E
}
