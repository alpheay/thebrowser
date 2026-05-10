import AppKit
import AuthenticationServices
import Combine
import Foundation

@MainActor
final class GoogleAccountStore: ObservableObject {
    enum SignInPhase: Equatable {
        case idle
        case signingIn
        case refreshing
    }

    static let shared = GoogleAccountStore()

    @Published private(set) var profile: GoogleProfile?
    @Published private(set) var phase: SignInPhase = .idle
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private let keychainAccount = "google.account.tokens"
    private let profileKey = "google.account.profile"
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var accessTokenExpiry: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDisk()
    }

    var isSignedIn: Bool { profile != nil }

    var clientID: String {
        let raw = defaults.string(forKey: PreferenceKey.googleOAuthClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw
    }

    var hasClientID: Bool { !clientID.isEmpty }

    func signIn(anchor: ASPresentationAnchor) async {
        guard phase != .signingIn else { return }
        phase = .signingIn
        lastError = nil

        let service = GoogleAuthService(clientID: clientID)
        do {
            let result = try await service.signIn(presentationAnchor: anchor)
            try persist(tokens: result.tokens, profile: result.profile)
        } catch GoogleAuthError.authorizationCanceled {
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        phase = .idle
    }

    func signOut() async {
        let token = cachedAccessToken ?? cachedRefreshToken
        if let token, hasClientID {
            await GoogleAuthService(clientID: clientID).revoke(token: token)
        }
        cachedAccessToken = nil
        cachedRefreshToken = nil
        accessTokenExpiry = nil
        profile = nil
        lastError = nil
        KeychainStore.delete(account: keychainAccount)
        defaults.removeObject(forKey: profileKey)
    }

    /// Returns a valid (non-expired) access token, refreshing if necessary.
    /// Returns nil if not signed in or refresh fails.
    @discardableResult
    func currentAccessToken() async -> String? {
        guard isSignedIn else { return nil }

        if let token = cachedAccessToken,
           let expiry = accessTokenExpiry,
           expiry > Date() {
            return token
        }

        guard let refreshToken = cachedRefreshToken else { return nil }
        guard hasClientID else { return nil }

        phase = .refreshing
        defer { phase = .idle }

        let service = GoogleAuthService(clientID: clientID)
        do {
            let refreshed = try await service.refresh(refreshToken: refreshToken)
            try persistTokens(refreshed)
            return refreshed.accessToken
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        if let data = defaults.data(forKey: profileKey),
           let decoded = try? JSONDecoder().decode(GoogleProfile.self, from: data) {
            profile = decoded
        }
        if let data = KeychainStore.load(account: keychainAccount),
           let snapshot = try? JSONDecoder().decode(StoredTokens.self, from: data) {
            cachedAccessToken = snapshot.accessToken
            cachedRefreshToken = snapshot.refreshToken
            accessTokenExpiry = snapshot.expiresAt
        }
    }

    private func persist(tokens: GoogleTokenSet, profile: GoogleProfile) throws {
        try persistTokens(tokens)
        let data = try JSONEncoder().encode(profile)
        defaults.set(data, forKey: profileKey)
        self.profile = profile
    }

    private func persistTokens(_ tokens: GoogleTokenSet) throws {
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
        try KeychainStore.save(data, account: keychainAccount)
    }

    private struct StoredTokens: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }
}
