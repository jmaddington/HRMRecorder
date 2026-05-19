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
        hr = HeartRateManager(db: db)
        uploader = SyncUploader(db: db, auth: auth)
        // Push a finished recording opportunistically (cold path only).
        hr.onSessionClosed = { [uploader] in uploader.trigger("stopRecording") }
    }
}
