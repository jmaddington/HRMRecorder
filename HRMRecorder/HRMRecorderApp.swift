import SwiftUI

@main
struct HRMRecorderApp: App {
    @StateObject private var model: AppModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model.hr)
                .environmentObject(model)
        }
    }
}

/// Owns the single database instance and the BLE manager bound to it.
final class AppModel: ObservableObject {
    let db = HRDatabase()
    let hr: HeartRateManager

    init() {
        hr = HeartRateManager(db: db)
    }
}
