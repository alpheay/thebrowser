import AppKit
import Foundation

@MainActor
final class DiscordAuthService {
    static let scope = "identify guilds"
    static let authorizationEndpoint = URL(string: "https://discord.com/oauth2/authorize")!
    static let tokenEndpoint = URL(string: "https://discord.com/api/oauth2/token")!
    static let revokeEndpoint = URL(string: "https://discord.com/api/oauth2/token/revoke")!
    static let userInfoEndpoint = URL(string: "https://discord.com/api/users/@me")!
    static let userGuildsEndpoint = URL(string: "https://discord.com/api/users/@me/guilds")!

    /// Native redirect URI users must register on their Discord application's
    /// OAuth2 settings page. WKWebView intercepts navigations whose scheme
    /// matches this — no Info.plist entry required.
    static let redirectURI = "thebrowser-discord://oauth/callback"
    static let callbackURLScheme = "thebrowser-discord"

    let clientID: String
    private let urlSession: URLSession

    init(clientID: String, urlSession: URLSession = .shared) {
        self.clientID = clientID
        self.urlSession = urlSession
    }

    typealias WebAuthPresenter = @MainActor (_ authURL: URL, _ callbackScheme: String) async throws -> URL

    func signIn(presenter: WebAuthPresenter) async throws -> (tokens: DiscordTokenSet, profile: DiscordProfile) {
        guard !clientID.isEmpty else { throw DiscordAuthError.missingClientID }

        let verifier = PKCE.codeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state = PKCE.randomString(length: 32)

        let authURL = try buildAuthorizationURL(challenge: challenge, state: state)
        let callbackURL = try await presenter(authURL, Self.callbackURLScheme)

        let code = try extractCode(from: callbackURL, expectedState: state)
        let tokens = try await exchange(code: code, verifier: verifier)
        let profile = try await fetchProfile(accessToken: tokens.accessToken)
        return (tokens, profile)
    }

    func refresh(refreshToken: String) async throws -> DiscordTokenSet {
        guard !clientID.isEmpty else { throw DiscordAuthError.missingClientID }
        let parameters: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        return try await postTokenRequest(parameters, fallbackRefreshToken: refreshToken)
    }

    func revoke(token: String) async {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "token=\(token)&client_id=\(clientID)&token_type_hint=access_token"
        request.httpBody = body.data(using: .utf8)
        _ = try? await urlSession.data(for: request)
    }

    func fetchProfile(accessToken: String) async throws -> DiscordProfile {
        var request = URLRequest(url: Self.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DiscordAuthError.profileRequestFailed(body.isEmpty ? "HTTP error" : body)
        }
        do {
            return try JSONDecoder().decode(DiscordProfile.self, from: data)
        } catch {
            throw DiscordAuthError.decodingFailed(decodingErrorSummary(error))
        }
    }

    func fetchGuilds(accessToken: String) async throws -> [DiscordGuild] {
        var request = URLRequest(url: Self.userGuildsEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DiscordAuthError.profileRequestFailed(body.isEmpty ? "HTTP error" : body)
        }
        do {
            return try JSONDecoder().decode([DiscordGuild].self, from: data)
        } catch {
            throw DiscordAuthError.decodingFailed(decodingErrorSummary(error))
        }
    }

    // MARK: - Building blocks

    private func buildAuthorizationURL(challenge: String, state: String) throws -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components?.url else {
            throw DiscordAuthError.authorizationFailed("Couldn't build the authorization URL.")
        }
        return url
    }

    private func extractCode(from callbackURL: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        if let errorValue = items.first(where: { $0.name == "error" })?.value {
            throw DiscordAuthError.authorizationFailed(errorValue)
        }

        let returnedState = items.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            throw DiscordAuthError.authorizationFailed("State mismatch — possible interception attempt.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw DiscordAuthError.missingCode
        }
        return code
    }

    private func exchange(code: String, verifier: String) async throws -> DiscordTokenSet {
        let parameters: [String: String] = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier
        ]
        return try await postTokenRequest(parameters, fallbackRefreshToken: nil)
    }

    private func postTokenRequest(_ parameters: [String: String], fallbackRefreshToken: String?) async throws -> DiscordTokenSet {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encodeForm(parameters)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DiscordAuthError.tokenRequestFailed(body.isEmpty ? "HTTP error" : body)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
        }

        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            let lifetime = decoded.expires_in ?? 604_800
            return DiscordTokenSet(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
                expiresAt: Date().addingTimeInterval(lifetime - 30),
                scope: decoded.scope
            )
        } catch {
            throw DiscordAuthError.decodingFailed(decodingErrorSummary(error))
        }
    }

    private func encodeForm(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        let raw = components.percentEncodedQuery ?? ""
        return Data(raw.utf8)
    }

    /// Reduces a `DecodingError` to a short, human-readable string —
    /// `typeMismatch on key permissions`, `valueNotFound on key id`, etc.
    /// Strips the bulky `userInfo` payload so the message fits in our error
    /// banner without leaking the raw JSON.
    private func decodingErrorSummary(_ error: Error) -> String? {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func keyPath(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(keyPath(context))"
        case .valueNotFound(let type, let context):
            return "missing \(type) at \(keyPath(context))"
        case .keyNotFound(let key, let context):
            return "missing key \(key.stringValue) under \(keyPath(context))"
        case .dataCorrupted(let context):
            return "malformed JSON at \(keyPath(context))"
        @unknown default:
            return "unrecognized decoding error"
        }
    }
}
