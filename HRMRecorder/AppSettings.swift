import Foundation

/// Non-sync app-wide preferences. Sync-engine state lives in `SyncSettings`.
enum AppSettings {

    private enum K {
        static let keepScreenOn = "display.keepScreenOnWhileAppOpen"
    }

    /// Registered once from `AppModel.init` so any read before the user
    /// touches the toggle returns the default.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            K.keepScreenOn: false,
        ])
    }

    /// When true, the idle timer stays disabled the whole time the app is
    /// foregrounded — not just while recording. Off by default to preserve
    /// battery for users who only record occasionally.
    static var keepScreenOnWhileAppOpen: Bool {
        get { UserDefaults.standard.bool(forKey: K.keepScreenOn) }
        set { UserDefaults.standard.set(newValue, forKey: K.keepScreenOn) }
    }
}
