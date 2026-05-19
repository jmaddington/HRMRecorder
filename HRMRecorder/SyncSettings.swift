import Foundation

/// Typed accessors over the small slice of `UserDefaults` shared with the
/// iOS **Settings.app** pane (`Settings.bundle/Root.plist`) plus the sync
/// engine's own bookkeeping.
///
/// Hard rules (CLAUDE.md / SYNC_PROTOCOL.md):
/// - **HTTPS only.** A non-`https://` base URL is rejected at use; there is
///   no insecure-HTTP toggle and no ATS exception (App-Store-clean).
/// - The user configures the **complete** base URL the operator hands out;
///   the app appends only relative resource segments — never a version or
///   path prefix of its own.
/// - The static token is a secret: it is migrated out of plist prefs into
///   the Keychain on first read and never written back.
enum SyncSettings {

    private enum K {
        static let enabled      = "sync.enabled"
        static let serverURL    = "sync.serverURL"
        static let staticToken  = "sync.staticToken"   // plist inbox only
        static let cursor       = "sync.cursorSampleID"
        static let lastResult   = "sync.lastResult"
    }

    /// Registered once from `AppModel.init` so the Settings.app pane shows
    /// the same defaults the app assumes before the user changes anything.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            K.enabled: false,
            K.serverURL: "",
        ])
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: Settings.app-backed

    static var isEnabled: Bool {
        get { defaults.bool(forKey: K.enabled) }
        set { defaults.set(newValue, forKey: K.enabled) }
    }

    /// Raw string exactly as typed in Settings.app (may be empty/invalid).
    static var serverURLString: String {
        get { defaults.string(forKey: K.serverURL) ?? "" }
        set { defaults.set(newValue, forKey: K.serverURL) }
    }

    /// The configured base **only if it is a valid `https://` URL**, with a
    /// guaranteed single trailing slash so relative segments append cleanly.
    /// Returns nil for empty/malformed/non-HTTPS input — callers must treat
    /// nil as "not configured / refuse to sync", never fall back to HTTP.
    static var validatedBaseURL: URL? {
        let raw = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let comps = URLComponents(string: raw),
              comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty
        else { return nil }
        let normalized = raw.hasSuffix("/") ? raw : raw + "/"
        return URL(string: normalized)
    }

    /// Append a protocol-relative resource segment (e.g. `ping`,
    /// `samples`, `sessions/abc`) to the validated base. nil propagates
    /// "not configured / non-HTTPS".
    static func resourceURL(_ relativePath: String) -> URL? {
        guard let base = validatedBaseURL else { return nil }
        let rel = relativePath.hasPrefix("/")
            ? String(relativePath.dropFirst()) : relativePath
        return URL(string: rel, relativeTo: base)?.absoluteURL
    }

    // MARK: Static token (secret → Keychain)

    /// The optional §3.2 static fallback token. If the user pasted one into
    /// the Settings.app secure field it lands in `UserDefaults`; on first
    /// read it is moved into the Keychain and scrubbed from prefs so the
    /// secret never persists in the plist. Returns the effective token.
    static var staticToken: String? {
        // Migrate a freshly-pasted value out of the plist inbox.
        if let pasted = defaults.string(forKey: K.staticToken),
           !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            Keychain.set(trimmed, for: .staticToken)
            defaults.removeObject(forKey: K.staticToken)
            return trimmed
        }
        return Keychain.get(.staticToken)
    }

    static func clearStaticToken() {
        defaults.removeObject(forKey: K.staticToken)
        Keychain.delete(.staticToken)
    }

    // MARK: Engine bookkeeping (non-secret)

    /// Highest acked `samples.id` (the protocol §8 cursor).
    static var cursorSampleID: Int {
        get { defaults.integer(forKey: K.cursor) }
        set { defaults.set(newValue, forKey: K.cursor) }
    }

    /// Last sync outcome, surfaced read-only in `ServerSyncView`.
    static var lastResult: String {
        get { defaults.string(forKey: K.lastResult) ?? "" }
        set { defaults.set(newValue, forKey: K.lastResult) }
    }
}
