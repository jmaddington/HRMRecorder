import Foundation
import SQLite3

/// SQLite3 wants a destructor argument; SQLITE_TRANSIENT tells it to copy the
/// bound bytes (the default-imported constant is unusable from Swift).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, dependency-free wrapper around libsqlite3.
///
/// One row per heart-rate notification, written the moment it arrives.
/// WAL + `synchronous = NORMAL` keeps each insert durable without stalling
/// the ~1 Hz capture stream. All access is funneled through one serial queue.
final class HRDatabase {

    struct SessionInfo: Identifiable, Hashable {
        let id: String
        let startedAt: Date
        let endedAt: Date?
        let deviceName: String?
        let manufacturer: String?
        let model: String?
        let firmware: String?
        let bodyLocation: String?
        let sampleCount: Int
    }

    let fileURL: URL

    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private let queue = DispatchQueue(label: "com.hrmrecorder.db")

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = support.appendingPathComponent("hrm.sqlite3")

        queue.sync {
            if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
                assertionFailure("Unable to open database at \(fileURL.path)")
                return
            }
            exec("PRAGMA journal_mode = WAL;")
            exec("PRAGMA synchronous = NORMAL;")
            exec("""
                CREATE TABLE IF NOT EXISTS sessions (
                    id            TEXT PRIMARY KEY,
                    started_at    REAL NOT NULL,
                    ended_at      REAL,
                    device_name   TEXT,
                    manufacturer  TEXT,
                    model         TEXT,
                    firmware      TEXT,
                    body_location TEXT
                );
                """)
            // Migrate older databases that predate the device-info columns.
            for col in ["manufacturer", "model", "firmware", "body_location"]
            where !columnExists("sessions", col) {
                exec("ALTER TABLE sessions ADD COLUMN \(col) TEXT;")
            }
            exec("""
                CREATE TABLE IF NOT EXISTS samples (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id  TEXT NOT NULL,
                    ts          REAL NOT NULL,
                    bpm         INTEGER NOT NULL,
                    rr_ms       TEXT,
                    contact     INTEGER,
                    energy_kj   INTEGER
                );
                """)
            exec("CREATE INDEX IF NOT EXISTS idx_samples_session ON samples(session_id);")
            exec("CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);")

            sqlite3_prepare_v2(db, """
                INSERT INTO samples (session_id, ts, bpm, rr_ms, contact, energy_kj)
                VALUES (?, ?, ?, ?, ?, ?);
                """, -1, &insertStmt, nil)
        }
    }

    deinit {
        queue.sync {
            if insertStmt != nil { sqlite3_finalize(insertStmt) }
            if db != nil { sqlite3_close(db) }
        }
    }

    // MARK: - Sessions

    func startSession(deviceName: String?) -> String {
        let id = ISO8601DateFormatter.compact.string(from: Date())
            + "-" + String(UInt16.random(in: 0...UInt16.max), radix: 16)
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db,
                "INSERT INTO sessions (id, started_at, device_name) VALUES (?, ?, ?);",
                -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                if let name = deviceName {
                    sqlite3_bind_text(stmt, 3, name, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        return id
    }

    func endSession(_ id: String) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db,
                "UPDATE sessions SET ended_at = ? WHERE id = ? AND ended_at IS NULL;",
                -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Attach sensor identity to a session. Device Information characteristics
    /// arrive asynchronously after connect, so this may be called repeatedly
    /// with partial data — COALESCE keeps the first non-null value for each
    /// field rather than clobbering it.
    func setSessionDevice(sessionID: String,
                          manufacturer: String?,
                          model: String?,
                          firmware: String?,
                          bodyLocation: String?) {
        queue.async {
            var stmt: OpaquePointer?
            let sql = """
                UPDATE sessions SET
                    manufacturer  = COALESCE(?, manufacturer),
                    model         = COALESCE(?, model),
                    firmware      = COALESCE(?, firmware),
                    body_location = COALESCE(?, body_location)
                WHERE id = ?;
                """
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                let bind: (Int32, String?) -> Void = { idx, value in
                    if let v = value {
                        sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, idx)
                    }
                }
                bind(1, manufacturer)
                bind(2, model)
                bind(3, firmware)
                bind(4, bodyLocation)
                sqlite3_bind_text(stmt, 5, sessionID, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Samples (hot path — fire and forget on the serial queue)

    func insertSample(sessionID: String,
                       date: Date,
                       bpm: Int,
                       rr: [Int],
                       contact: Bool?,
                       energyKJ: Int?) {
        queue.async {
            guard let stmt = self.insertStmt else { return }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(bpm))
            if rr.isEmpty {
                sqlite3_bind_null(stmt, 4)
            } else {
                sqlite3_bind_text(stmt, 4, rr.map(String.init).joined(separator: ";"),
                                  -1, SQLITE_TRANSIENT)
            }
            if let c = contact {
                sqlite3_bind_int(stmt, 5, c ? 1 : 0)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let e = energyKJ {
                sqlite3_bind_int(stmt, 6, Int32(e))
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_step(stmt)
        }
    }

    // MARK: - Reads

    func sessions() -> [SessionInfo] {
        queue.sync {
            var out: [SessionInfo] = []
            var stmt: OpaquePointer?
            let sql = """
                SELECT s.id, s.started_at, s.ended_at, s.device_name,
                       s.manufacturer, s.model, s.firmware, s.body_location,
                       (SELECT COUNT(*) FROM samples x WHERE x.session_id = s.id)
                FROM sessions s
                ORDER BY s.started_at DESC;
                """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let textOrNil: (Int32) -> String? = { col in
                    sqlite3_column_type(stmt, col) == SQLITE_NULL
                        ? nil : String(cString: sqlite3_column_text(stmt, col))
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let started = sqlite3_column_double(stmt, 1)
                    let ended: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                    out.append(SessionInfo(id: id,
                                           startedAt: Date(timeIntervalSince1970: started),
                                           endedAt: ended,
                                           deviceName: textOrNil(3),
                                           manufacturer: textOrNil(4),
                                           model: textOrNil(5),
                                           firmware: textOrNil(6),
                                           bodyLocation: textOrNil(7),
                                           sampleCount: Int(sqlite3_column_int(stmt, 8))))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    func session(id: String) -> SessionInfo? {
        sessions().first { $0.id == id }
    }

    func totalSampleCount() -> Int {
        scalarCount("SELECT COUNT(*) FROM samples;", bind: nil)
    }

    func sampleCount(sessionID: String) -> Int {
        scalarCount("SELECT COUNT(*) FROM samples WHERE session_id = ?;", bind: sessionID)
    }

    // MARK: - Maintenance

    func deleteSession(_ id: String) {
        queue.async {
            self.run("DELETE FROM samples WHERE session_id = ?;", text: id)
            self.run("DELETE FROM sessions WHERE id = ?;", text: id)
        }
    }

    func deleteAll() {
        queue.async {
            self.exec("DELETE FROM samples;")
            self.exec("DELETE FROM sessions;")
            self.exec("VACUUM;")
        }
    }

    // MARK: - CSV export

    /// Streams matching rows into a CSV file in the temp directory and returns
    /// its URL. Pass `nil` to export every session.
    /// Export samples as CSV. `from`/`to` (when given) bound `samples.ts`
    /// inclusively-from / exclusively-to, so a caller passing start-of-day
    /// and start-of-next-day gets whole calendar days. Both nil = full
    /// history (unchanged legacy behavior). When a date range is supplied
    /// but matches no samples, no file is written and nil is returned.
    func exportCSV(sessionID: String?, from: Date? = nil, to: Date? = nil) -> URL? {
        queue.sync {
            let stamp = ISO8601DateFormatter.compact.string(from: Date())
            let name = sessionID.map { "HRM_\($0).csv" } ?? "HRM_all_\(stamp).csv"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else { return nil }
            defer { try? handle.close() }

            handle.write(Data("timestamp_iso,unix_seconds,session_id,device_name,manufacturer,model,firmware,body_location,bpm,rr_ms,sensor_contact,energy_kj\n".utf8))

            var stmt: OpaquePointer?
            let cols = """
                s.ts, s.session_id, e.device_name, e.manufacturer, e.model,
                e.firmware, e.body_location, s.bpm, s.rr_ms, s.contact, s.energy_kj
                """
            var predicates: [String] = []
            if sessionID != nil { predicates.append("s.session_id = ?") }
            if from != nil      { predicates.append("s.ts >= ?") }
            if to != nil        { predicates.append("s.ts < ?") }
            let whereClause = predicates.isEmpty
                ? "" : " WHERE " + predicates.joined(separator: " AND ")
            let sql = "SELECT \(cols) FROM samples s "
                + "LEFT JOIN sessions e ON e.id = s.session_id"
                + "\(whereClause) ORDER BY s.ts ASC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            var bindIdx: Int32 = 1
            if let sid = sessionID {
                sqlite3_bind_text(stmt, bindIdx, sid, -1, SQLITE_TRANSIENT); bindIdx += 1
            }
            if let from = from {
                sqlite3_bind_double(stmt, bindIdx, from.timeIntervalSince1970); bindIdx += 1
            }
            if let to = to {
                sqlite3_bind_double(stmt, bindIdx, to.timeIntervalSince1970); bindIdx += 1
            }

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let field: (Int32) -> String = { col in
                sqlite3_column_type(stmt, col) == SQLITE_NULL
                    ? "" : Self.csvEscape(String(cString: sqlite3_column_text(stmt, col)))
            }
            var buffer = ""
            var rowCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                rowCount += 1
                let ts = sqlite3_column_double(stmt, 0)
                let sid = field(1)
                let deviceName = field(2)
                let manufacturer = field(3)
                let model = field(4)
                let firmware = field(5)
                let bodyLoc = field(6)
                let bpm = sqlite3_column_int(stmt, 7)
                let rr = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? "" : String(cString: sqlite3_column_text(stmt, 8))
                let contact = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                    ? "" : String(sqlite3_column_int(stmt, 9))
                let energy = sqlite3_column_type(stmt, 10) == SQLITE_NULL
                    ? "" : String(sqlite3_column_int(stmt, 10))
                let isoStr = iso.string(from: Date(timeIntervalSince1970: ts))
                buffer += "\(isoStr),\(ts),\(sid),\(deviceName),\(manufacturer),\(model),\(firmware),\(bodyLoc),\(bpm),\(rr),\(contact),\(energy)\n"
                if buffer.utf8.count > 64 * 1024 {
                    handle.write(Data(buffer.utf8))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { handle.write(Data(buffer.utf8)) }
            sqlite3_finalize(stmt)

            // A date-filtered export that matched nothing yields no file
            // (graceful empty-range handling) rather than a header-only CSV.
            if rowCount == 0, from != nil || to != nil {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return url
        }
    }

    // MARK: - Private helpers (must be called on `queue`)

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// RFC-4180 quoting so a manufacturer/model containing a comma, quote, or
    /// newline can't break the CSV layout.
    private static func csvEscape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func columnExists(_ table: String, _ column: String) -> Bool {
        var stmt: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if String(cString: sqlite3_column_text(stmt, 1)) == column { found = true }
            }
        }
        sqlite3_finalize(stmt)
        return found
    }

    private func run(_ sql: String, text: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func scalarCount(_ sql: String, bind: String?) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            var value = 0
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let b = bind { sqlite3_bind_text(stmt, 1, b, -1, SQLITE_TRANSIENT) }
                if sqlite3_step(stmt) == SQLITE_ROW { value = Int(sqlite3_column_int(stmt, 0)) }
            }
            sqlite3_finalize(stmt)
            return value
        }
    }
}

extension ISO8601DateFormatter {
    /// Filename-safe timestamp, e.g. `20260518T143012Z`.
    static let compact: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay,
                           .withTime, .withTimeZone]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
