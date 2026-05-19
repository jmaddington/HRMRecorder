import ActivityKit
import Foundation

/// Shared between the app and the `HRMWidgets` Live Activity extension.
///
/// This file lives in a non-synchronized `Shared/` folder and is registered
/// to both targets' Sources phases by hand: a `PBXFileSystemSynchronizedRootGroup`
/// makes every file under it a member of exactly one target, so a type that
/// must compile into *both* the app and the extension cannot live in either
/// synced folder. It is therefore compiled twice (once per target) — that is
/// expected, not a duplicate-symbol bug (the two builds are separate modules).
///
/// Guarded `@available(iOS 16.1, *)` because ActivityKit's floor is iOS 16.1
/// and the extension target deploys to 16.1; the project compiles with
/// `CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE`.
@available(iOS 16.1, *)
struct HRMActivityAttributes: ActivityAttributes {

    /// The part of the Live Activity that changes over the session's life.
    struct ContentState: Codable, Hashable {
        var bpm: Int
        /// `nil` when the strap doesn't report skin-contact support.
        var sensorContact: Bool?
        var deviceName: String
        var lastUpdate: Date
        /// BPM of any additional straps recording into the same session.
        /// Optional so a single-strap payload is byte-identical to before
        /// (decodes fine against the old struct; nil → rendered as today).
        var secondaryBPMs: [Int]? = nil
    }

    /// Fixed for the activity's lifetime. Powers `Text(_, style: .timer)` in
    /// the widget so the elapsed clock animates locally between content
    /// updates at zero update-budget cost.
    var sessionStartedAt: Date
}
