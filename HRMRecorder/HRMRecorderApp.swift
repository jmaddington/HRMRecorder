import SwiftUI

@main
struct HRMRecorderApp: App {
    @StateObject private var model: AppModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(model.hr)
                .environmentObject(model)
                .environmentObject(model.uploader)
        }
        .onChange(of: scenePhase) { phase in
            // Cold-path trigger only (crash-resumed / finished sessions get
            // pushed when the app backgrounds or returns) — never the 1 Hz
            // capture path. No-op unless sync is enabled.
            if phase == .background || phase == .active {
                model.uploader.trigger("scenePhase:\(phase)")
            }
            // Re-apply the screen-on policy on foreground in case the user
            // toggled "Keep screen on" in another app (Settings.app pane)
            // or another scene-phase transition cleared it.
            if phase == .active {
                model.hr.refreshIdleTimer()
            }
        }
    }

    // AIDEV-NOTE: DEBUG-only screenshot root-swap. Launch args drive the app
    // to open directly on a target screen so marketing screenshots are
    // deterministic and re-shootable without coordinate-guessing UI taps.
    // Release builds always render the normal ContentView.
    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-HRMScreenshotSessions") {
            NavigationStack { SessionsView() }
        } else if args.contains("-HRMScreenshotPicker") {
            DevicePickerView(onSelect: { _ in })
        } else if args.contains("-HRMScreenshotGraphs") {
            NavigationStack { HRHistoryGraphView() }
        } else if args.contains("-HRMScreenshotSessionGraph"),
                  let target = Self.sessionGraphScreenshotTarget(model.db) {
            // Combine with -HRMSeedFakeSessions so a fixture session exists.
            NavigationStack { SessionGraphView(session: target) }
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }

    #if DEBUG
    /// Session shown by `-HRMScreenshotSessionGraph`: prefer the intervals
    /// fixture (the most dramatic curve), else the newest session. DEBUG
    /// screenshot path only — this sync read never runs in Release.
    private static func sessionGraphScreenshotTarget(_ db: HRDatabase) -> HRDatabase.SessionInfo? {
        let sessions = db.sessions()
        return sessions.first { $0.id == "fixture-2026-cyclingintervals" } ?? sessions.first
    }
    #endif
}

/// Owns the single database, the BLE manager bound to it, and the optional
/// sync stack (auth + uploader). The sync stack is inert until the user
/// configures and enables it; a sync failure can never affect recording.
@MainActor
final class AppModel: ObservableObject {
    let db = HRDatabase()
    let hr: HeartRateManager
    let auth = SyncAuth()
    let uploader: SyncUploader

    init() {
        SyncSettings.registerDefaults()
        AppSettings.registerDefaults()
        #if DEBUG
        // Idempotent fixture seeding; no-op without launch arg -HRMSeedFakeSessions.
        SessionFixtures.seedIfRequested(into: db)
        // Verification helper for HRMRecorder-dc5: runs the real exportCSV
        // path against current DB contents and copies the file to
        // Documents/ so it's reachable via simctl get_app_container.
        if ProcessInfo.processInfo.arguments.contains("-HRMExportCSVOnLaunch") {
            if let src = db.exportCSV(sessionID: nil),
               let docs = try? FileManager.default.url(for: .documentDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil,
                                                       create: true) {
                let dst = docs.appendingPathComponent("HRM_export_verification.csv")
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                NSLog("[HRMRecorder] Exported CSV to \(dst.path) [DC5-EXPORT-VERIFY]")
            }
        }
        #endif
        hr = HeartRateManager(db: db)
        uploader = SyncUploader(db: db, auth: auth)
        // Push a finished recording opportunistically (cold path only).
        hr.onSessionClosed = { [uploader] in uploader.trigger("stopRecording") }
        #if DEBUG
        // Verification helper for HRMRecorder-9fo and screenshot capture:
        // auto-starts recording 1.5s after launch (gives the synthetic source
        // time to feed at least one sample so the session is non-empty).
        if ProcessInfo.processInfo.arguments.contains("-HRMAutoRecord") {
            let weakHR = hr
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak weakHR] in
                weakHR?.startRecording()
            }
        }
        #endif
        // Nudge a sync every ~1000 captured samples so a long continuous
        // recording doesn't accumulate unsynced data between background/stop
        // events. trigger() is non-blocking and a no-op unless sync is enabled.
        hr.onSampleThreshold = { [uploader] in uploader.trigger("sampleThreshold") }
    }
}
