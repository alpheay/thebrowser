import Foundation

/// Loads OAuth client credentials for an integration from a file in
/// Application Support that is intentionally outside the repository.
///
/// The expected location is
/// `~/Library/Application Support/TheBrowser/Integrations/<name>/credentials.json`,
/// matching the JSON shape Google Cloud Console emits when you download a
/// Desktop or iOS OAuth client (i.e. wrapped in an `installed` object).
///
/// Keeping secrets here — rather than in source, UserDefaults, or bundled
/// resources — means the repo can be made public without leaking anything.
/// Tokens minted via these credentials are persisted in the Keychain by
/// the integration's own store.
enum IntegrationCredentialsLoader {
    struct InstalledClient: Decodable, Equatable {
        var clientID: String
        var clientSecret: String?
        var authURI: URL?
        var tokenURI: URL?
        var redirectURIs: [String]

        var isUsable: Bool { !clientID.isEmpty }

        var primaryRedirectURI: String? {
            redirectURIs.first(where: { !$0.isEmpty })
        }
    }

    private struct Envelope: Decodable {
        let installed: Payload?
        let web: Payload?

        struct Payload: Decodable {
            let client_id: String
            let client_secret: String?
            let auth_uri: String?
            let token_uri: String?
            let redirect_uris: [String]?
        }
    }

    enum LoadError: LocalizedError {
        case missing(URL)
        case malformed(URL, underlying: String)

        var errorDescription: String? {
            switch self {
            case .missing(let url):
                return "Couldn't find credentials at \(url.path). Drop the OAuth Desktop client JSON Google gave you there."
            case .malformed(let url, let underlying):
                return "The credentials file at \(url.path) didn't parse: \(underlying)"
            }
        }
    }

    /// `~/Library/Application Support/TheBrowser/Integrations/<integration>/credentials.json`.
    static func defaultLocation(for integration: String) -> URL {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: true) {
            base = appSupport
        } else {
            base = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return base
            .appendingPathComponent("TheBrowser", isDirectory: true)
            .appendingPathComponent("Integrations", isDirectory: true)
            .appendingPathComponent(integration, isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
    }

    static func load(integration: String) throws -> InstalledClient {
        try load(from: defaultLocation(for: integration))
    }

    static func load(from url: URL) throws -> InstalledClient {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw LoadError.missing(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.malformed(url, underlying: error.localizedDescription)
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw LoadError.malformed(url, underlying: error.localizedDescription)
        }
        guard let payload = envelope.installed ?? envelope.web else {
            throw LoadError.malformed(url, underlying: "missing 'installed' / 'web' object")
        }
        return InstalledClient(
            clientID: payload.client_id,
            clientSecret: payload.client_secret,
            authURI: payload.auth_uri.flatMap(URL.init(string:)),
            tokenURI: payload.token_uri.flatMap(URL.init(string:)),
            redirectURIs: payload.redirect_uris ?? []
        )
    }
}
