import ActivityKit
import Foundation
import os

private let log = Logger(subsystem: "com.jmaddington.HRMRecorder",
                         category: "LiveActivity")

/// Owns the single lock-screen / Dynamic Island Live Activity for the
/// recording session and brokers all ActivityKit calls.
///
/// Used exclusively from `HeartRateManager`, whose `CBCentralManager` runs on
/// the main queue — so every method here is already called on the main thread.
/// The class is deliberately *not* `@MainActor`: that would force `await` at
/// the synchronous, main-thread `HeartRateManager` call sites and reintroduce
/// the Swift-concurrency friction `SWIFT_VERSION = 5.0` exists to avoid. The
/// only genuinely async ActivityKit calls (`update`/`end`) are wrapped in a
/// detached `Task` internally; `Activity.request` is synchronous.
///
/// Annotated `@available(iOS 16.2, *)`: the app target deploys to iOS 18.6 so
/// the modern (non-deprecated) `ActivityContent` / async `update`/`end` API is
/// used. Live Activities themselves are iOS 16.1+, which the extension target
/// (deployment 16.1) satisfies; only this controller — app-side — needs 16.2.
@available(iOS 16.2, *)
final class LiveActivityController {

    private var activity: Activity<HRMActivityAttributes>?

    /// Device name is constant for a session; captured on start/adopt so the
    /// throttled `update` path doesn't need it threaded through every reading.
    private var deviceName = "Heart-Rate Strap"

    /// Throttle state. The ~1 Hz `ingest` hot path must not spend the iOS
    /// background Live Activity update budget on every reading.
    private var lastPushedAt = Date.distantPast
    private var lastPushedBPM = -1
    private var lastPushedContact: Bool??
    private let minInterval: TimeInterval = 2
    private let significantBPMDelta = 5

    /// Begin a Live Activity for a freshly started recording session.
    func start(deviceName: String, sessionStartedAt: Date, bpm: Int, contact: Bool?) {
        guard activity == nil else {
            log.notice("start: skipped, an activity is already running")
            return
        }
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        log.notice("start: areActivitiesEnabled=\(enabled, privacy: .public)")
        guard enabled else {
            log.error("start: Live Activities are DISABLED — enable them in Settings ▸ HRM Recorder ▸ Live Activities (and Settings ▸ Face ID & Passcode ▸ Live Activities for the lock screen).")
            return
        }

        self.deviceName = deviceName
        let attributes = HRMActivityAttributes(sessionStartedAt: sessionStartedAt)
        let state = HRMActivityAttributes.ContentState(
            bpm: bpm, sensorContact: contact,
            deviceName: deviceName, lastUpdate: Date())
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            self.activity = activity
            lastPushedAt = Date()
            lastPushedBPM = bpm
            lastPushedContact = contact
            log.notice("start: requested activity id=\(activity.id, privacy: .public) bpm=\(bpm)")
        } catch {
            // Live Activity is best-effort glanceable UI — never let its
            // failure affect recording.
            activity = nil
            log.error("start: Activity.request threw: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Push a new reading, throttled to protect the background update budget:
    /// at most one update every `minInterval`s, but always on a significant
    /// BPM swing or a skin-contact change so the lock screen stays honest.
    func update(bpm: Int, contact: Bool?, now: Date) {
        guard let activity else { return }
        let dueByTime = now.timeIntervalSince(lastPushedAt) >= minInterval
        let bigSwing = abs(bpm - lastPushedBPM) >= significantBPMDelta
        let contactChanged = lastPushedContact != .some(contact)
        guard dueByTime || bigSwing || contactChanged else { return }

        lastPushedAt = now
        lastPushedBPM = bpm
        lastPushedContact = contact
        let state = HRMActivityAttributes.ContentState(
            bpm: bpm, sensorContact: contact,
            deviceName: deviceName, lastUpdate: now)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// End and immediately dismiss the activity when recording stops.
    func end() {
        guard let activity else { return }
        self.activity = nil
        resetThrottle()
        log.notice("end: dismissing activity id=\(activity.id, privacy: .public)")
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// After a process restart mid-session, re-attach to a still-running
    /// activity if iOS kept one alive; otherwise start a fresh one.
    func adopt(deviceName: String, sessionStartedAt: Date, bpm: Int, contact: Bool?) {
        if let existing = Activity<HRMActivityAttributes>.activities.first {
            self.deviceName = deviceName
            activity = existing
            resetThrottle()
            log.notice("adopt: re-attached to existing activity id=\(existing.id, privacy: .public)")
        } else {
            log.notice("adopt: no running activity, starting a fresh one")
            start(deviceName: deviceName,
                  sessionStartedAt: sessionStartedAt, bpm: bpm, contact: contact)
        }
    }

    private func resetThrottle() {
        lastPushedAt = .distantPast
        lastPushedBPM = -1
        lastPushedContact = nil
    }
}
