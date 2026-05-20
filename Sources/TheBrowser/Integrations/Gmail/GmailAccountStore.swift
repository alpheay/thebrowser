import AppKit
import Combine
import Foundation

/// Owns Gmail OAuth state: which Google identity is signed in, the tokens
/// needed to call the Gmail API, and where the underlying client
/// credentials came from. Tokens are persisted in the Keychain; the rest
/// (profile, expiry hints) live in UserDefaults.
@MainActor
final class GmailAccountStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case signingIn
        case refreshing
    }

    struct Identity: Codable, Equatable {
        let email: String
        let name: String?
        let pictureURL: String?
    }

    static let shared = GmailAccountStore()

    @Published private(set) var identity: Identity?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var credentialsState: CredentialsState = .loading
    @Published var pendingWebAuth: GmailWebAuthRequest?

    enum CredentialsState: Equatable {
        case loading
        case ready(clientID: String)
        case missing(message: String)

        var clientID: String? {
            if case .ready(let id) = self { return id }
            return nil
        }
    }

    private let defaults: UserDefaults
    private let keychainService = "com.thebrowser.gmailIntegration"
    private let tokenAccount = "gmail.integration.tokens"
    private let identityKey = "gmail.integration.identity"

    private var clientID: String = ""
    private var clientSecret: String? = nil
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var accessTokenExpiry: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadIdentityFromDisk()
        loadTokensFromKeychain()
        reloadCredentials()
    }

    var isSignedIn: Bool { identity != nil && cachedRefreshToken != nil }

    /// Re-reads `~/Library/Application Support/TheBrowser/Integrations/Gmail/credentials.json`.
    /// Called on init and whenever the user prods the "reload" button in
    /// the Gmail launcher.
    func reloadCredentials() {
        do {
            let client = try IntegrationCredentialsLoader.load(integration: "Gmail")
            clientID = client.clientID
            clientSecret = client.clientSecret
            credentialsState = .ready(clientID: client.clientID)
        } catch {
            clientID = ""
            clientSecret = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            credentialsState = .missing(message: message)
        }
    }

    func signIn() async {
        guard phase != .signingIn else { return }
        guard case .ready = credentialsState else {
            lastError = "Gmail credentials aren't loaded. Reload and try again."
            return
        }
        phase = .signingIn
        lastError = nil

        let service = GmailOAuthService(clientID: clientID, clientSecret: clientSecret)
        do {
            let tokens = try await service.signIn { [weak self] authURL in
                try await self?.presentWebAuth(url: authURL)
                    ?? { throw GmailAuthError.authorizationCanceled }()
            }
            try persistTokens(tokens)
            await refreshIdentity(using: tokens.accessToken)
        } catch GmailAuthError.authorizationCanceled {
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        phase = .idle
    }

    private func presentWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let request = GmailWebAuthRequest(
                url: url,
                callbackHost: GmailOAuthService.callbackHost
            ) { [weak self] result in
                self?.pendingWebAuth = nil
                continuation.resume(with: result)
            }
            pendingWebAuth = request
        }
    }

    func signOut() async {
        if let token = cachedAccessToken ?? cachedRefreshToken, !clientID.isEmpty {
            await GmailOAuthService(clientID: clientID, clientSecret: clientSecret).revoke(token: token)
        }
        cachedAccessToken = nil
        cachedRefreshToken = nil
        accessTokenExpiry = nil
        identity = nil
        lastError = nil
        KeychainStore.delete(account: tokenAccount, service: keychainService)
        defaults.removeObject(forKey: identityKey)
    }

    /// Returns a valid access token, refreshing via the refresh token if
    /// the cached one has expired. Returns nil if the user isn't signed in
    /// or credentials/the refresh round-trip failed.
    @discardableResult
    func currentAccessToken() async -> String? {
        guard let refresh = cachedRefreshToken else { return nil }
        if let token = cachedAccessToken,
           let expiry = accessTokenExpiry,
           expiry > Date() {
            return token
        }
        guard case .ready = credentialsState else { return nil }
        phase = .refreshing
        defer { phase = .idle }

        let service = GmailOAuthService(clientID: clientID, clientSecret: clientSecret)
        do {
            let refreshed = try await service.refresh(refreshToken: refresh)
            try persistTokens(refreshed)
            return refreshed.accessToken
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Identity

    private func refreshIdentity(using accessToken: String) async {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            struct Payload: Decodable {
                let email: String
                let name: String?
                let picture: String?
            }
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            let identity = Identity(email: decoded.email, name: decoded.name, pictureURL: decoded.picture)
            self.identity = identity
            if let payload = try? JSONEncoder().encode(identity) {
                defaults.set(payload, forKey: identityKey)
            }
        } catch {
            // Profile is a nice-to-have; missing it shouldn't fail sign-in.
        }
    }

    // MARK: - Persistence

    private struct StoredTokens: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    private func loadIdentityFromDisk() {
        if let data = defaults.data(forKey: identityKey),
           let decoded = try? JSONDecoder().decode(Identity.self, from: data) {
            identity = decoded
        }
    }

    private func loadTokensFromKeychain() {
        if let data = KeychainStore.load(account: tokenAccount, service: keychainService),
           let snapshot = try? JSONDecoder().decode(StoredTokens.self, from: data) {
            cachedAccessToken = snapshot.accessToken
            cachedRefreshToken = snapshot.refreshToken
            accessTokenExpiry = snapshot.expiresAt
        }
    }

    private func persistTokens(_ tokens: GmailTokenSet) throws {
        cachedAccessToken = tokens.accessToken
        if let refresh = tokens.refreshToken {
            cachedRefreshToken = refresh
        }
        accessTokenExpiry = tokens.expiresAt

        let snapshot = StoredTokens(
            accessToken: tokens.accessToken,
            refreshToken: cachedRefreshToken,
            expiresAt: tokens.expiresAt
        )
        let data = try JSONEncoder().encode(snapshot)
        try KeychainStore.save(data, account: tokenAccount, service: keychainService)
    }
}
