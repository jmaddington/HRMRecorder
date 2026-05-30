import SwiftUI

@main
struct HRMRecorderApp: App {
    @StateObject private var model: AppModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
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
        #endif
        hr = HeartRateManager(db: db)
        uploader = SyncUploader(db: db, auth: auth)
        // Push a finished recording opportunistically (cold path only).
        hr.onSessionClosed = { [uploader] in uploader.trigger("stopRecording") }
        // Nudge a sync every ~1000 captured samples so a long continuous
        // recording doesn't accumulate unsynced data between background/stop
        // events. trigger() is non-blocking and a no-op unless sync is enabled.
        hr.onSampleThreshold = { [uploader] in uploader.trigger("sampleThreshold") }
    }
}
