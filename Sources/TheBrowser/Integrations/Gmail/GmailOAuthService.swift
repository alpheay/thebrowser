import Foundation

enum GmailAuthError: LocalizedError {
    case missingCredentials(String)
    case malformedClientID
    case authorizationCanceled
    case authorizationFailed(String)
    case missingCode
    case tokenRequestFailed(String)
    case decodingFailed(String?)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let detail):
            return "Gmail credentials aren't loaded: \(detail)"
        case .malformedClientID:
            return "Gmail client ID isn't a Google OAuth client."
        case .authorizationCanceled:
            return "Sign-in canceled."
        case .authorizationFailed(let message):
            return "Sign-in failed: \(message)"
        case .missingCode:
            return "Google didn't return an authorization code."
        case .tokenRequestFailed(let message):
            return "Token exchange failed: \(message)"
        case .decodingFailed(let detail):
            return "Couldn't read Google's response\(detail.map { " (\($0))" } ?? "")."
        case .notSignedIn:
            return "Sign in to Gmail to continue."
        }
    }
}

struct GmailTokenSet {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?
}

/// OAuth flow tailored to a Google **Desktop** client (the JSON has an
/// `installed` envelope with `client_secret` and `http://localhost` in
/// `redirect_uris`). We never actually open a localhost listener — the
/// embedded WKWebView in ``GmailAuthWebSheet`` cancels the redirect before
/// it touches the network and hands us the URL with `code` and `state`.
@MainActor
final class GmailOAuthService {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Scopes wide enough to power inbox + reply + send + label toggles
    /// (star/archive). `gmail.modify` covers everything but full delete.
    static let scopes: [String] = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send"
    ]

    /// Desktop OAuth clients are pinned to `http://localhost` (with any
    /// port). We just use the bare host: the webview intercepts the
    /// navigation, so no port is ever actually bound.
    static let redirectURI = "http://localhost"
    /// "Scheme" the auth sheet matches on. Desktop redirects come back as
    /// `http://localhost?...`, so we match on host instead — but the sheet
    /// expects a string identifier so we name it `http`.
    static let callbackURLScheme = "http"
    static let callbackHost = "localhost"

    let clientID: String
    let clientSecret: String?
    private let urlSession: URLSession

    init(clientID: String, clientSecret: String?, urlSession: URLSession = .shared) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.urlSession = urlSession
    }

    typealias WebAuthPresenter = @MainActor (_ authURL: URL) async throws -> URL

    func signIn(presenter: WebAuthPresenter) async throws -> GmailTokenSet {
        guard !clientID.isEmpty else { throw GmailAuthError.missingCredentials("client_id is empty") }
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw GmailAuthError.malformedClientID
        }

        let verifier = PKCE.codeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state = PKCE.randomString(length: 32)

        let authURL = try buildAuthorizationURL(challenge: challenge, state: state)
        let callbackURL = try await presenter(authURL)
        let code = try extractCode(from: callbackURL, expectedState: state)
        return try await exchange(code: code, verifier: verifier)
    }

    func refresh(refreshToken: String) async throws -> GmailTokenSet {
        var parameters: [String: String] = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret { parameters["client_secret"] = clientSecret }
        return try await postTokenRequest(parameters, fallbackRefreshToken: refreshToken)
    }

    func revoke(token: String) async {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token)".data(using: .utf8)
        _ = try? await urlSession.data(for: request)
    }

    // MARK: - Building blocks

    private func buildAuthorizationURL(challenge: String, state: String) throws -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "prompt", value: "consent select_account")
        ]
        guard let url = components?.url else {
            throw GmailAuthError.authorizationFailed("Couldn't build the authorization URL.")
        }
        return url
    }

    private func extractCode(from callbackURL: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        if let errorValue = items.first(where: { $0.name == "error" })?.value {
            throw GmailAuthError.authorizationFailed(errorValue)
        }
        let returnedState = items.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            throw GmailAuthError.authorizationFailed("State mismatch — possible interception attempt.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GmailAuthError.missingCode
        }
        return code
    }

    private func exchange(code: String, verifier: String) async throws -> GmailTokenSet {
        var parameters: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI
        ]
        if let clientSecret { parameters["client_secret"] = clientSecret }
        return try await postTokenRequest(parameters, fallbackRefreshToken: nil)
    }

    private func postTokenRequest(_ parameters: [String: String], fallbackRefreshToken: String?) async throws -> GmailTokenSet {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encodeForm(parameters)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GmailAuthError.tokenRequestFailed(body.isEmpty ? "HTTP error" : body)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
        }

        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            let lifetime = decoded.expires_in ?? 3_600
            return GmailTokenSet(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
                expiresAt: Date().addingTimeInterval(lifetime - 30),
                scope: decoded.scope
            )
        } catch {
            throw GmailAuthError.decodingFailed(error.localizedDescription)
        }
    }

    private func encodeForm(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        let raw = components.percentEncodedQuery ?? ""
        return Data(raw.utf8)
    }
}
