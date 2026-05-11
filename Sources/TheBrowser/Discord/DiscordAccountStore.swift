import AppKit
import Combine
import Foundation

@MainActor
final class DiscordAccountStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case signingIn
        case refreshing
        case loadingGuilds
    }

    static let shared = DiscordAccountStore()

    @Published private(set) var profile: DiscordProfile?
    @Published private(set) var guilds: [DiscordGuild] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?
    @Published var pendingWebAuth: DiscordWebAuthRequest?

    private let defaults: UserDefaults
    private let keychainService = "com.thebrowser.discordAccount"
    private let tokenAccount = "discord.account.tokens"
    private let profileKey = "discord.account.profile"
    private let guildsKey = "discord.account.guilds"

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var accessTokenExpiry: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDisk()
    }

    var isSignedIn: Bool { profile != nil }

    var clientID: String {
        let raw = defaults.string(forKey: PreferenceKey.discordOAuthClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw
    }

    var hasClientID: Bool { !clientID.isEmpty }

    func signIn() async {
        guard phase != .signingIn else { return }
        phase = .signingIn
        lastError = nil

        let service = DiscordAuthService(clientID: clientID)
        do {
            let result = try await service.signIn { [weak self] authURL, callbackScheme in
                try await self?.presentWebAuth(url: authURL, callbackScheme: callbackScheme)
                    ?? { throw DiscordAuthError.authorizationCanceled }()
            }
            try persist(tokens: result.tokens, profile: result.profile)
            phase = .idle
            await refreshGuilds()
            return
        } catch DiscordAuthError.authorizationCanceled {
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        phase = .idle
    }

    private func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let request = DiscordWebAuthRequest(url: url, callbackScheme: callbackScheme) { [weak self] result in
                self?.pendingWebAuth = nil
                continuation.resume(with: result)
            }
            pendingWebAuth = request
        }
    }

    func signOut() async {
        let token = cachedAccessToken ?? cachedRefreshToken
        if let token, hasClientID {
            await DiscordAuthService(clientID: clientID).revoke(token: token)
        }
        cachedAccessToken = nil
        cachedRefreshToken = nil
        accessTokenExpiry = nil
        profile = nil
        guilds = []
        lastError = nil
        KeychainStore.delete(account: tokenAccount, service: keychainService)
        defaults.removeObject(forKey: profileKey)
        defaults.removeObject(forKey: guildsKey)
    }

    /// Returns a valid (non-expired) access token, refreshing if necessary.
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

        let service = DiscordAuthService(clientID: clientID)
        do {
            let refreshed = try await service.refresh(refreshToken: refreshToken)
            try persistTokens(refreshed)
            return refreshed.accessToken
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Refreshes the cached guild list. Safe to call on a stale session — if
    /// the token has expired we fall back to the refresh-token path before
    /// hitting the guilds endpoint.
    func refreshGuilds() async {
        guard isSignedIn else { return }
        guard let token = await currentAccessToken() else { return }

        phase = .loadingGuilds
        defer { phase = .idle }

        let service = DiscordAuthService(clientID: clientID)
        do {
            let fetched = try await service.fetchGuilds(accessToken: token)
            guilds = fetched.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            persistGuilds()
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-fetches the user's profile (avatar, banner, display name). Cheap;
    /// called when the client window opens so a refreshed avatar lands the
    /// moment the launcher appears.
    func refreshProfile() async {
        guard isSignedIn else { return }
        guard let token = await currentAccessToken() else { return }

        let service = DiscordAuthService(clientID: clientID)
        do {
            let fetched = try await service.fetchProfile(accessToken: token)
            profile = fetched
            persistProfile(fetched)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        if let data = defaults.data(forKey: profileKey),
           let decoded = try? JSONDecoder().decode(DiscordProfile.self, from: data) {
            profile = decoded
        }
        if let data = defaults.data(forKey: guildsKey),
           let decoded = try? JSONDecoder().decode([DiscordGuild].self, from: data) {
            guilds = decoded
        }
        if let data = KeychainStore.load(account: tokenAccount, service: keychainService),
           let snapshot = try? JSONDecoder().decode(StoredTokens.self, from: data) {
            cachedAccessToken = snapshot.accessToken
            cachedRefreshToken = snapshot.refreshToken
            accessTokenExpiry = snapshot.expiresAt
        }
    }

    private func persist(tokens: DiscordTokenSet, profile: DiscordProfile) throws {
        try persistTokens(tokens)
        persistProfile(profile)
        self.profile = profile
    }

    private func persistProfile(_ profile: DiscordProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: profileKey)
        }
    }

    private func persistGuilds() {
        if let data = try? JSONEncoder().encode(guilds) {
            defaults.set(data, forKey: guildsKey)
        }
    }

    private func persistTokens(_ tokens: DiscordTokenSet) throws {
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

    private struct StoredTokens: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }
}
