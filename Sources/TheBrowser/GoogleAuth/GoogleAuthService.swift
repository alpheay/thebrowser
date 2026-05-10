import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

enum GoogleAuthError: LocalizedError {
    case missingClientID
    case malformedClientID
    case authorizationCanceled
    case authorizationFailed(String)
    case missingCode
    case tokenRequestFailed(String)
    case profileRequestFailed(String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Add a Google OAuth Client ID below to enable sign-in."
        case .malformedClientID:
            return "That doesn't look like a Google OAuth Client ID. It should end in .apps.googleusercontent.com."
        case .authorizationCanceled:
            return "Sign-in canceled."
        case .authorizationFailed(let message):
            return "Google sign-in failed: \(message)"
        case .missingCode:
            return "Google didn't return an authorization code."
        case .tokenRequestFailed(let message):
            return "Token exchange failed: \(message)"
        case .profileRequestFailed(let message):
            return "Couldn't fetch your Google profile: \(message)"
        case .decodingFailed:
            return "Google returned a response we couldn't read."
        }
    }
}

struct GoogleTokenSet {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
}

struct GoogleProfile: Codable, Equatable {
    var subject: String
    var email: String
    var name: String?
    var pictureURL: String?
    var verifiedEmail: Bool

    private enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case email
        case name
        case pictureURL = "picture"
        case verifiedEmail = "email_verified"
    }

    init(subject: String, email: String, name: String?, pictureURL: String?, verifiedEmail: Bool) {
        self.subject = subject
        self.email = email
        self.name = name
        self.pictureURL = pictureURL
        self.verifiedEmail = verifiedEmail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subject = try container.decode(String.self, forKey: .subject)
        email = try container.decode(String.self, forKey: .email)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pictureURL = try container.decodeIfPresent(String.self, forKey: .pictureURL)
        verifiedEmail = (try? container.decode(Bool.self, forKey: .verifiedEmail))
            ?? Bool((try? container.decode(String.self, forKey: .verifiedEmail)) ?? "")
            ?? false
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return email
    }

    var initials: String {
        let source = (name?.isEmpty == false ? name! : email)
        let pieces = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
        let initials = pieces.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }
}

@MainActor
final class GoogleAuthService {
    static let scope = "openid email profile"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let userinfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    let clientID: String
    private let urlSession: URLSession

    init(clientID: String, urlSession: URLSession = .shared) {
        self.clientID = clientID
        self.urlSession = urlSession
    }

    /// Google's "iOS" OAuth client redirect URI is the reverse of the client ID
    /// prefix (everything before `.apps.googleusercontent.com`) with a fixed
    /// path. ASWebAuthenticationSession intercepts URLs that begin with this
    /// scheme — no Info.plist registration required.
    var redirectURI: String {
        get throws {
            let suffix = ".apps.googleusercontent.com"
            guard clientID.hasSuffix(suffix) else {
                throw GoogleAuthError.malformedClientID
            }
            let prefix = String(clientID.dropLast(suffix.count))
            let reversed = "com.googleusercontent.apps." + prefix
            return reversed + ":/oauth2redirect"
        }
    }

    var callbackURLScheme: String {
        get throws {
            let uri = try redirectURI
            return uri.components(separatedBy: ":").first ?? ""
        }
    }

    func signIn(presentationAnchor: ASPresentationAnchor) async throws -> (tokens: GoogleTokenSet, profile: GoogleProfile) {
        guard !clientID.isEmpty else { throw GoogleAuthError.missingClientID }

        let verifier = PKCE.codeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state = PKCE.randomString(length: 32)
        let redirect = try redirectURI
        let scheme = try callbackURLScheme

        let authURL = try buildAuthorizationURL(
            challenge: challenge,
            state: state,
            redirectURI: redirect
        )

        let callbackURL = try await presentAuthSession(
            authURL: authURL,
            callbackScheme: scheme,
            anchor: presentationAnchor
        )

        let code = try extractCode(from: callbackURL, expectedState: state)
        let tokens = try await exchange(code: code, verifier: verifier, redirectURI: redirect)
        let profile = try await fetchProfile(accessToken: tokens.accessToken)
        return (tokens, profile)
    }

    func refresh(refreshToken: String) async throws -> GoogleTokenSet {
        guard !clientID.isEmpty else { throw GoogleAuthError.missingClientID }
        let parameters: [String: String] = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
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

    private func buildAuthorizationURL(
        challenge: String,
        state: String,
        redirectURI: String
    ) throws -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account")
        ]
        guard let url = components?.url else {
            throw GoogleAuthError.authorizationFailed("Couldn't build the authorization URL.")
        }
        return url
    }

    private func presentAuthSession(
        authURL: URL,
        callbackScheme: String,
        anchor: ASPresentationAnchor
    ) async throws -> URL {
        let provider = PresentationContextProvider.shared(for: anchor)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            // Completion handler must be @Sendable so it does not inherit
            // @MainActor isolation from the enclosing class. ASWebAuthenticationSession
            // invokes the callback on a background XPC reply queue on macOS 26,
            // which traps Swift's executor assertion if the closure is MainActor-isolated.
            let handler: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: GoogleAuthError.authorizationCanceled)
                    } else {
                        continuation.resume(throwing: GoogleAuthError.authorizationFailed(error.localizedDescription))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: GoogleAuthError.authorizationFailed("Empty callback."))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme,
                completionHandler: handler
            )
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: GoogleAuthError.authorizationFailed("System refused to start the sign-in sheet."))
            }
        }
    }

    private func extractCode(from callbackURL: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        if let errorValue = items.first(where: { $0.name == "error" })?.value {
            throw GoogleAuthError.authorizationFailed(errorValue)
        }

        let returnedState = items.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            throw GoogleAuthError.authorizationFailed("State mismatch — possible interception attempt.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GoogleAuthError.missingCode
        }
        return code
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> GoogleTokenSet {
        let parameters: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        return try await postTokenRequest(parameters, fallbackRefreshToken: nil)
    }

    private func postTokenRequest(_ parameters: [String: String], fallbackRefreshToken: String?) async throws -> GoogleTokenSet {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encodeForm(parameters)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAuthError.tokenRequestFailed(body.isEmpty ? "HTTP error" : body)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Double?
        }

        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            let lifetime = decoded.expires_in ?? 3_600
            return GoogleTokenSet(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
                idToken: decoded.id_token,
                expiresAt: Date().addingTimeInterval(lifetime - 30)
            )
        } catch {
            throw GoogleAuthError.decodingFailed
        }
    }

    private func fetchProfile(accessToken: String) async throws -> GoogleProfile {
        var request = URLRequest(url: Self.userinfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAuthError.profileRequestFailed(body.isEmpty ? "HTTP error" : body)
        }
        do {
            return try JSONDecoder().decode(GoogleProfile.self, from: data)
        } catch {
            throw GoogleAuthError.decodingFailed
        }
    }

    private func encodeForm(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        let raw = components.percentEncodedQuery ?? ""
        return Data(raw.utf8)
    }
}

// MARK: - PKCE

enum PKCE {
    static func codeVerifier() -> String {
        randomString(length: 64)
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func randomString(length: Int) -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[alphabet.index(alphabet.startIndex, offsetBy: Int($0) % alphabet.count)] })
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - ASWebAuthenticationSession anchor

@MainActor
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var instances: [ObjectIdentifier: PresentationContextProvider] = [:]
    private weak var anchor: ASPresentationAnchor?

    static func shared(for anchor: ASPresentationAnchor) -> PresentationContextProvider {
        let key = ObjectIdentifier(anchor)
        if let existing = instances[key], existing.anchor != nil {
            return existing
        }
        let provider = PresentationContextProvider()
        provider.anchor = anchor
        instances[key] = provider
        return provider
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchor ?? NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        }
    }
}
