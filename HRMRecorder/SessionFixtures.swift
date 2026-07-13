#if DEBUG
import Foundation

/// DEBUG-only pre-seeded session history. Behind launch arg
/// `-HRMSeedFakeSessions` (Edit Scheme → Run → Arguments). Drops a small
/// set of plausible historical sessions into the SQLite DB so the sessions
/// list, per-session CSVs, and the all-data CSV export look real in
/// marketing screenshots — no need for a real strap or a real recording
/// history.
///
/// Idempotent: each fixture session has a deterministic id and is only
/// inserted when missing, so re-launching with the flag never duplicates.
/// Exception: the "recent" fixture (`reanchoredIDs`) is deleted and reseeded
/// on every seeded launch so it stays ~3 h old instead of aging out of the
/// 1H/6H/24H graph ranges. Additive otherwise: it never deletes or touches
/// the user's real sessions.
///
/// AIDEV-NOTE: Two fake strap UUIDs (`primaryStrapID`, `backupStrapID`) so
/// one fixture session can exercise the per-sample multi-strap attribution
/// path that the CSV export depends on.
enum SessionFixtures {

    // Deterministic strap UUIDs (stable across launches → idempotent).
    private static let primaryStrapID = UUID(uuidString: "F12734E1-0000-4000-8000-000000000001")!
    private static let backupStrapID  = UUID(uuidString: "F12734E1-0000-4000-8000-000000000002")!

    // AIDEV-NOTE: fixtures re-anchored to now on EVERY seeded launch (delete+reseed) so short
    // graph ranges never go empty as the fixture ages; the rest seed once and age naturally.
    private static let reanchoredIDs: Set<String> = ["fixture-2026-lunchrun"]

    static func seedIfRequested(into db: HRDatabase) {
        guard ProcessInfo.processInfo.arguments.contains("-HRMSeedFakeSessions") else { return }
        seed(into: db)
    }

    private static func seed(into db: HRDatabase) {
        // Register the two strap identities (idempotent via setDevice's INSERT OR IGNORE).
        db.setDevice(id: primaryStrapID.uuidString,
                     name: "HRM-Pro+ (fixture)",
                     manufacturer: "Garmin",
                     model: "HRM-Pro+",
                     firmware: "12.10",
                     bodyLocation: "Chest")
        db.setDevice(id: backupStrapID.uuidString,
                     name: "Polar H10 (fixture)",
                     manufacturer: "Polar Electro Oy",
                     model: "H10",
                     firmware: "3.1.1",
                     bodyLocation: "Chest")

        // Anchor the fixtures to "now" so the timeline always looks fresh.
        let now = Date()
        for spec in specs(reference: now) {
            if reanchoredIDs.contains(spec.id) {
                // deleteSession is queue.async and the seed helpers are
                // queue.sync on the same serial queue, so delete lands first.
                db.deleteSession(spec.id)
                insert(spec, into: db)
            } else if !db.sessionExists(id: spec.id) {
                insert(spec, into: db)
            }
        }
    }

    // MARK: - Fixture specs

    private struct Spec {
        let id: String
        let startedAt: Date
        let durationSeconds: Int
        let label: String          // shown as the session's device_name
        let deviceID: UUID
        let manufacturer: String
        let model: String
        let firmware: String
        let bodyLocation: String
        let bpmCurve: (Int) -> Int   // (secondsSinceStart) -> bpm
        /// Optional second strap recording into the same session, for the
        /// multi-strap CSV attribution path. nil → single-strap session.
        let secondaryDeviceID: UUID?
    }

    private static func specs(reference now: Date) -> [Spec] {

        // Helpers for natural BPM curves. All return Int BPM.

        func restWalk(baseline: Int, amplitude: Int) -> (Int) -> Int {
            { sec in
                let drift = sin(Double(sec) / 22.0) * Double(amplitude)
                let jitter = Double(Int.random(in: -1...1))
                return Int((Double(baseline) + drift + jitter).rounded())
            }
        }

        // Smooth ramp-and-plateau: warm 90s, hold high, cool 60s.
        func steadyCardio(rest: Int, peak: Int) -> (Int) -> Int {
            { sec in
                let s = Double(sec)
                let ramp = min(1.0, s / 90.0)
                let cooldownStart = 1500.0
                let cool = max(0.0, min(1.0, (s - cooldownStart) / 90.0))
                let raw = Double(rest) + (Double(peak) - Double(rest)) * (ramp - cool * 0.6)
                let jitter = Double(Int.random(in: -2...2))
                return Int((raw + jitter).rounded().clamped(to: 40...190))
            }
        }

        // 6× hard intervals after a 5-min warm-up; rests in between.
        func cyclingIntervals(rest: Int, peak: Int) -> (Int) -> Int {
            { sec in
                let warmup = 300
                if sec < warmup {
                    let ramp = Double(sec) / Double(warmup)
                    return Int((Double(rest) + Double(peak - rest) * 0.5 * ramp).rounded())
                }
                // 6 reps × (180s hard + 120s easy)
                let cycle = 300
                let into = (sec - warmup) % cycle
                let raw: Int
                if into < 180 {
                    let ramp = Double(into) / 60.0      // 60s ramp up to peak
                    raw = Int((Double(rest) + Double(peak - rest) * min(1.0, ramp)).rounded())
                } else {
                    let down = Double(into - 180) / 60.0
                    raw = Int((Double(peak) - Double(peak - rest) * min(1.0, down)).rounded())
                }
                let jitter = Int.random(in: -3...3)
                return (raw + jitter).clamped(to: 40...195)
            }
        }

        // POTS-style standing test: 5 min sitting baseline, then standing
        // triggers a fast jump and a slow climb (per HR criteria for POTS).
        func standingTest(sitting: Int, standingTarget: Int) -> (Int) -> Int {
            { sec in
                if sec < 300 {                        // sitting baseline
                    let jitter = Int.random(in: -2...2)
                    return (sitting + jitter).clamped(to: 40...190)
                }
                let into = Double(sec - 300)
                // Sharp first 30s, then continued slow climb.
                let fast = min(1.0, into / 30.0)
                let slow = min(1.0, into / 300.0)
                let raw = Double(sitting) +
                    Double(standingTarget - sitting) * (0.55 * fast + 0.45 * slow)
                let jitter = Double(Int.random(in: -2...2))
                return Int((raw + jitter).rounded()).clamped(to: 40...190)
            }
        }

        // Meditation: slow decline.
        func meditation(start: Int, end: Int) -> (Int) -> Int {
            { sec in
                let progress = min(1.0, Double(sec) / 480.0)
                let raw = Double(start) + (Double(end) - Double(start)) * progress
                let jitter = Double(Int.random(in: -1...1))
                return Int((raw + jitter).rounded())
            }
        }

        let day: TimeInterval = 86_400
        let primary = primaryStrapID
        let backup = backupStrapID

        return [
            // Recent session (~3h ago) so the history graph's 6H/24H ranges
            // aren't empty in -HRMScreenshotGraphs captures (the other
            // fixtures all sit 2+ days back and only show at 7D/30D).
            Spec(id: "fixture-2026-lunchrun",
                 startedAt: now.addingTimeInterval(-3 * 3600),
                 durationSeconds: 42 * 60,
                 label: "HRM-Pro+ (fixture)",
                 deviceID: primary,
                 manufacturer: "Garmin", model: "HRM-Pro+", firmware: "12.10",
                 bodyLocation: "Chest",
                 bpmCurve: steadyCardio(rest: 74, peak: 158),
                 secondaryDeviceID: nil),

            Spec(id: "fixture-2026-restmorning",
                 startedAt: now.addingTimeInterval(-2 * day - 9 * 3600),
                 durationSeconds: 14 * 60,
                 label: "HRM-Pro+ (fixture)",
                 deviceID: primary,
                 manufacturer: "Garmin", model: "HRM-Pro+", firmware: "12.10",
                 bodyLocation: "Chest",
                 bpmCurve: restWalk(baseline: 62, amplitude: 4),
                 secondaryDeviceID: nil),

            Spec(id: "fixture-2026-standingtest",
                 startedAt: now.addingTimeInterval(-3 * day - 16 * 3600),
                 durationSeconds: 12 * 60,
                 label: "HRM-Pro+ (fixture)",
                 deviceID: primary,
                 manufacturer: "Garmin", model: "HRM-Pro+", firmware: "12.10",
                 bodyLocation: "Chest",
                 bpmCurve: standingTest(sitting: 76, standingTarget: 128),
                 secondaryDeviceID: nil),

            Spec(id: "fixture-2026-meditation",
                 startedAt: now.addingTimeInterval(-5 * day - 21 * 3600),
                 durationSeconds: 9 * 60,
                 label: "HRM-Pro+ (fixture)",
                 deviceID: primary,
                 manufacturer: "Garmin", model: "HRM-Pro+", firmware: "12.10",
                 bodyLocation: "Chest",
                 bpmCurve: meditation(start: 74, end: 56),
                 secondaryDeviceID: nil),

            Spec(id: "fixture-2026-recoverywalk",
                 startedAt: now.addingTimeInterval(-8 * day - 11 * 3600),
                 durationSeconds: 32 * 60,
                 label: "HRM-Pro+ (fixture)",
                 deviceID: primary,
                 manufacturer: "Garmin", model: "HRM-Pro+", firmware: "12.10",
                 bodyLocation: "Chest",
                 bpmCurve: restWalk(baseline: 92, amplitude: 6),
                 secondaryDeviceID: nil),

            Spec(id: "fixture-2026-tempo-multistrap",
                 startedAt: now.addingTimeInterval(-13 * day - 17 * 3600),
                 durationSeconds: 28 * 60,
                 label: "HRM-Pro+ (fixture)",
                 deviceID: primary,
                 manufacturer: "Garmin", model: "HRM-Pro+", firmware: "12.10",
                 bodyLocation: "Chest",
                 bpmCurve: steadyCardio(rest: 78, peak: 152),
                 secondaryDeviceID: backup),     // dual-strap session

            Spec(id: "fixture-2026-cyclingintervals",
                 startedAt: now.addingTimeInterval(-20 * day - 18 * 3600),
                 durationSeconds: 38 * 60,
                 label: "HRM-Pro+ (fixture)",
                 deviceID: primary,
                 manufacturer: "Garmin", model: "HRM-Pro+", firmware: "12.10",
                 bodyLocation: "Chest",
                 bpmCurve: cyclingIntervals(rest: 78, peak: 168),
                 secondaryDeviceID: nil),
        ]
    }

    // MARK: - Insert

    private static func insert(_ spec: Spec, into db: HRDatabase) {
        let endedAt = spec.startedAt.addingTimeInterval(TimeInterval(spec.durationSeconds))
        db.seedSession(id: spec.id, startedAt: spec.startedAt, endedAt: endedAt,
                       deviceName: spec.label,
                       manufacturer: spec.manufacturer,
                       model: spec.model,
                       firmware: spec.firmware,
                       bodyLocation: spec.bodyLocation)

        var samples: [HRDatabase.FixtureSample] = []
        samples.reserveCapacity(spec.durationSeconds + 16)

        for second in 0..<spec.durationSeconds {
            let ts = spec.startedAt.addingTimeInterval(TimeInterval(second))
            let bpm = spec.bpmCurve(second)
            let rr = rrIntervals(forBPM: bpm)

            // Primary strap always reports.
            samples.append(HRDatabase.FixtureSample(
                sessionID: spec.id, ts: ts, bpm: bpm, rr: rr,
                contact: true, deviceID: spec.deviceID.uuidString))

            // Secondary strap (for multi-strap sessions) reports a slightly
            // different BPM, every 2 seconds, so attribution-per-row stays
            // visible in CSV exports.
            if let secondary = spec.secondaryDeviceID, second % 2 == 0 {
                let altBpm = bpm + Int.random(in: -3...3)
                samples.append(HRDatabase.FixtureSample(
                    sessionID: spec.id, ts: ts, bpm: altBpm,
                    rr: rrIntervals(forBPM: altBpm),
                    contact: true, deviceID: secondary.uuidString))
            }
        }

        db.seedSamples(samples)
    }

    /// Derive 1–3 R-R intervals from a BPM with realistic millisecond
    /// jitter, matching what real straps emit per Heart Rate Measurement
    /// packet. Lower BPM → longer intervals; jitter is what HRV analysis
    /// actually feeds on.
    private static func rrIntervals(forBPM bpm: Int) -> [Int] {
        let safe = max(35, min(200, bpm))
        let base = 60_000 / safe
        let count = Int.random(in: 1...3)
        return (0..<count).map { _ in
            max(250, base + Int.random(in: -28...28))
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif
