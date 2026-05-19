import Foundation
import AuthenticationServices
import CryptoKit

/// Auth coordinator for the Server Sync Protocol §3.
///
/// Discovers how to authenticate from the unauthenticated `GET <base>/ping`,
/// then either drives a full OAuth 2.1 sign-in (RFC 8414 discovery → RFC 7591
/// dynamic client registration → Authorization Code + PKCE S256 in a system
/// web auth session → token + refresh) or uses the static fallback token.
/// Exposes one thing the uploader needs: `currentBearer()`.
///
/// Reuses the server's *existing* authorization server — on jmdashboard the
/// same OAuth 2.1 AS already used by `/api/v1/` and MCP. No server changes.
///
/// Every failure is recoverable and surfaced via `SyncSettings.lastResult`;
/// nothing here can affect recording or the local DB (CLAUDE.md).
@MainActor
final class SyncAuth: NSObject {

    enum AuthMode: String { case oauth, token }

    struct Discovery {
        let mode: AuthMode
        let maxSamplesPerRequest: Int
        let oauthMetadataURL: URL?
    }

    enum AuthError: LocalizedError {
        case notConfigured, pingUnreachable, noOAuthMetadata
        case registrationFailed, authorizationFailed, tokenExchangeFailed
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .notConfigured:      return "Set a server URL in Settings."
            case .pingUnreachable:    return "Server unreachable — check the URL."
            case .noOAuthMetadata:    return "Server did not advertise OAuth."
            case .registrationFailed: return "OAuth client registration failed."
            case .authorizationFailed:return "Sign-in was cancelled or failed."
            case .tokenExchangeFailed:return "Token exchange failed."
            case .notSignedIn:        return "Sign in to enable sync."
            }
        }
    }

    // Persisted OAuth client + endpoints (no secrets — kept with the
    // token bundle in the Keychain so refresh needs no network rediscovery).
    private struct ClientState: Codable {
        var clientID: String
        var authorizationEndpoint: String
        var tokenEndpoint: String
    }

    private let session = URLSession(configuration: .ephemeral)
    private let redirectURI = "hrmrecorder://oauth-callback"
    private let scope = "api:read api:write"

    private let expiryKey = "sync.oauthExpiry"

    // MARK: - Discovery

    /// `GET <base>/ping` (unauthenticated). Returns nil only if the server
    /// is unreachable / not configured — callers treat that as "can't sync
    /// right now", never as an error that touches recording.
    func discover() async -> Discovery? {
        guard let url = SyncSettings.resourceURL("ping") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("1", forHTTPHeaderField: "X-HRM-Protocol")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let ping = try? JSONDecoder().decode(PingResponse.self, from: data)
        else { return nil }
        let mode = AuthMode(rawValue: ping.auth?.mode ?? "token") ?? .token
        return Discovery(
            mode: mode,
            maxSamplesPerRequest: ping.limits?.maxSamplesPerRequest ?? 1000,
            oauthMetadataURL: ping.auth?.oauthMetadataURL
                .flatMap(URL.init(string:)))
    }

    // MARK: - Bearer for the uploader

    /// The bearer to put on data requests, or nil when sync can't proceed
    /// (not configured / signed out / offline). Never throws — sync is
    /// best-effort and must not perturb recording.
    func currentBearer() async -> String? {
        guard SyncSettings.validatedBaseURL != nil else { return nil }
        guard let disc = await discover() else {
            // ping unreachable: fall back to a static token if the user set
            // one (a minimal server may have no ping), else give up quietly.
            return SyncSettings.staticToken
        }
        switch disc.mode {
        case .token:
            return SyncSettings.staticToken
        case .oauth:
            if let valid = unexpiredAccessToken() { return valid }
            return try? await refreshAccessToken()
        }
    }

    var isSignedIn: Bool { clientState() != nil && Keychain.get(.oauthRefresh) != nil }

    func signOut() {
        Keychain.delete(.oauthAccess)
        Keychain.delete(.oauthRefresh)
        Keychain.delete(.oauthClient)
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }

    // MARK: - Interactive sign-in (called from ServerSyncView)

    func signIn() async throws {
        guard SyncSettings.validatedBaseURL != nil else { throw AuthError.notConfigured }
        guard let disc = await discover() else { throw AuthError.pingUnreachable }
        guard disc.mode == .oauth, let metaURL = disc.oauthMetadataURL else {
            throw AuthError.noOAuthMetadata
        }
        let meta = try await fetchMetadata(metaURL)
        let client = try await ensureClient(meta)

        let verifier = Self.pkceVerifier()
        let challenge = Self.pkceChallenge(verifier)
        let state = UUID().uuidString

        var comps = URLComponents(string: client.authorizationEndpoint)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = comps.url else { throw AuthError.authorizationFailed }

        let callback = try await present(authURL)
        guard let cb = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              cb.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = cb.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw AuthError.authorizationFailed }

        try await exchangeCode(code, verifier: verifier, client: client)
        SyncSettings.lastResult = "Signed in \(Self.now())"
    }

    // MARK: - OAuth steps

    private func fetchMetadata(_ url: URL) async throws -> OAuthMetadata {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let meta = try? JSONDecoder().decode(OAuthMetadata.self, from: data)
        else { throw AuthError.noOAuthMetadata }
        return meta
    }

    /// Reuse a stored registration; otherwise RFC 7591 dynamic registration
    /// as a public native client (no operator-side app config required).
    private func ensureClient(_ meta: OAuthMetadata) async throws -> ClientState {
        if let existing = clientState() { return existing }
        guard let regEndpoint = meta.registrationEndpoint,
              let regURL = URL(string: regEndpoint) else {
            throw AuthError.registrationFailed
        }
        var req = URLRequest(url: regURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "HRM Recorder",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
            "scope": scope,
        ])
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...201).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = obj["client_id"] as? String
        else { throw AuthError.registrationFailed }

        let state = ClientState(
            clientID: clientID,
            authorizationEndpoint: meta.authorizationEndpoint,
            tokenEndpoint: meta.tokenEndpoint)
        saveClientState(state)
        return state
    }

    private func exchangeCode(_ code: String, verifier: String,
                              client: ClientState) async throws {
        let body = Self.form([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": client.clientID,
            "code_verifier": verifier,
        ])
        try await tokenRequest(body, tokenEndpoint: client.tokenEndpoint)
    }

    /// Silent refresh (used on 401 and when the access token is expired).
    @discardableResult
    private func refreshAccessToken() async throws -> String? {
        guard let client = clientState(),
              let refresh = Keychain.get(.oauthRefresh) else {
            throw AuthError.notSignedIn
        }
        let body = Self.form([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": client.clientID,
        ])
        do {
            try await tokenRequest(body, tokenEndpoint: client.tokenEndpoint)
            return Keychain.get(.oauthAccess)
        } catch {
            // Refresh expired/revoked → require interactive sign-in again.
            SyncSettings.lastResult = "Sign in again \(Self.now())"
            throw error
        }
    }

    private func tokenRequest(_ body: Data, tokenEndpoint: String) async throws {
        guard let url = URL(string: tokenEndpoint) else {
            throw AuthError.tokenExchangeFailed
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tok = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { throw AuthError.tokenExchangeFailed }

        Keychain.set(tok.accessToken, for: .oauthAccess)
        if let rt = tok.refreshToken { Keychain.set(rt, for: .oauthRefresh) }
        let expiry = Date().addingTimeInterval(
            TimeInterval(tok.expiresIn ?? 3600))
        UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: expiryKey)
    }

    // MARK: - Token/state helpers

    private func unexpiredAccessToken() -> String? {
        guard let token = Keychain.get(.oauthAccess) else { return nil }
        let expiry = UserDefaults.standard.double(forKey: expiryKey)
        // 60s skew margin so we refresh just before the server rejects.
        guard expiry == 0 || Date().timeIntervalSince1970 < expiry - 60
        else { return nil }
        return token
    }

    private func clientState() -> ClientState? {
        guard let json = Keychain.get(.oauthClient),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClientState.self, from: data)
    }

    private func saveClientState(_ s: ClientState) {
        if let data = try? JSONEncoder().encode(s),
           let json = String(data: data, encoding: .utf8) {
            Keychain.set(json, for: .oauthClient)
        }
    }

    // MARK: - PKCE / encoding

    private static func pkceVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func form(_ params: [String: String]) -> Data {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=")
        let pairs = params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: cs) ?? v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    // MARK: - System web auth session

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let webSession = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "hrmrecorder"
            ) { callback, error in
                if let callback {
                    cont.resume(returning: callback)
                } else {
                    cont.resume(throwing: error ?? AuthError.authorizationFailed)
                }
            }
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            if !webSession.start() {
                cont.resume(throwing: AuthError.authorizationFailed)
            }
        }
    }
}

extension SyncAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - Wire models (decoders only; the protocol owns these shapes)

struct PingResponse: Decodable {
    struct Limits: Decodable {
        let maxSamplesPerRequest: Int?
        enum CodingKeys: String, CodingKey {
            case maxSamplesPerRequest = "max_samples_per_request"
        }
    }
    struct Auth: Decodable {
        let mode: String?
        let oauthMetadataURL: String?
        enum CodingKeys: String, CodingKey {
            case mode
            case oauthMetadataURL = "oauth_metadata_url"
        }
    }
    let ok: Bool?
    let limits: Limits?
    let auth: Auth?
}

struct OAuthMetadata: Decodable {
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let registrationEndpoint: String?
    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
