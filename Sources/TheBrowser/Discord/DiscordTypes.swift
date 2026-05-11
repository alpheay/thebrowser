import Foundation

enum DiscordAuthError: LocalizedError {
    case missingClientID
    case authorizationCanceled
    case authorizationFailed(String)
    case missingCode
    case tokenRequestFailed(String)
    case profileRequestFailed(String)
    case decodingFailed(String?)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Add a Discord OAuth Client ID below to enable sign-in."
        case .authorizationCanceled:
            return "Sign-in canceled."
        case .authorizationFailed(let message):
            return "Discord sign-in failed: \(message)"
        case .missingCode:
            return "Discord didn't return an authorization code."
        case .tokenRequestFailed(let message):
            return "Token exchange failed: \(message)"
        case .profileRequestFailed(let message):
            return "Couldn't fetch your Discord profile: \(message)"
        case .decodingFailed(let detail):
            if let detail, !detail.isEmpty {
                return "Discord returned a response we couldn't read: \(detail)"
            }
            return "Discord returned a response we couldn't read."
        }
    }
}

struct DiscordTokenSet {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?
}

/// User payload returned from `GET /users/@me`. Tracks both the modern
/// `global_name` (post-Pomelo display name) and the legacy
/// `username#discriminator` pair so older accounts still render correctly.
struct DiscordProfile: Codable, Equatable {
    var id: String
    var username: String
    var globalName: String?
    var discriminator: String
    var avatar: String?
    var email: String?
    var verified: Bool?
    var banner: String?
    var accentColor: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case globalName = "global_name"
        case discriminator
        case avatar
        case email
        case verified
        case banner
        case accentColor = "accent_color"
    }

    var displayName: String {
        if let globalName, !globalName.isEmpty { return globalName }
        return username
    }

    /// Discord post-Pomelo migration uses "0" as the placeholder discriminator
    /// for accounts on the new unique-username system. Legacy accounts still
    /// have a four-digit tag.
    var legacyTag: String? {
        guard discriminator != "0", !discriminator.isEmpty else { return nil }
        return "#" + discriminator
    }

    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return defaultAvatarURL }
        let ext = avatar.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).\(ext)?size=128")
    }

    /// Discord's CDN exposes six default avatars; post-Pomelo accounts pick
    /// by `(id >> 22) % 6`, legacy accounts use `discriminator % 5`.
    var defaultAvatarURL: URL? {
        let index: Int
        if discriminator == "0", let snowflake = UInt64(id) {
            index = Int((snowflake >> 22) % 6)
        } else {
            index = (Int(discriminator) ?? 0) % 5
        }
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(index).png")
    }

    var initials: String {
        let source = (globalName?.isEmpty == false ? globalName! : username)
        let pieces = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
        let initials = pieces.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }
}

/// Partial guild payload from `GET /users/@me/guilds`. We don't pull the full
/// guild object (channels, roles, members) because that requires either
/// elevated OAuth scopes or a bot token — this listing is just for the
/// launcher's server rail.
struct DiscordGuild: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var icon: String?
    var owner: Bool?
    var features: [String]?
    var approximateMemberCount: Int?
    var approximatePresenceCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case owner
        case features
        case approximateMemberCount = "approximate_member_count"
        case approximatePresenceCount = "approximate_presence_count"
    }

    /// Discord's `permissions` field has historically alternated between
    /// integer and string forms; we don't render it in the launcher, so we
    /// skip it entirely rather than risk a type-mismatch failure on the whole
    /// guild list. Same idea for any other field Discord might add later:
    /// extra JSON keys are ignored, missing optionals stay `nil`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        owner = try c.decodeIfPresent(Bool.self, forKey: .owner)
        features = try c.decodeIfPresent([String].self, forKey: .features)
        approximateMemberCount = try c.decodeIfPresent(Int.self, forKey: .approximateMemberCount)
        approximatePresenceCount = try c.decodeIfPresent(Int.self, forKey: .approximatePresenceCount)
    }

    init(id: String, name: String, icon: String? = nil, owner: Bool? = nil, features: [String]? = nil, approximateMemberCount: Int? = nil, approximatePresenceCount: Int? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.owner = owner
        self.features = features
        self.approximateMemberCount = approximateMemberCount
        self.approximatePresenceCount = approximatePresenceCount
    }

    var iconURL: URL? {
        guard let icon, !icon.isEmpty else { return nil }
        let ext = icon.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/icons/\(id)/\(icon).\(ext)?size=128")
    }

    /// Two-letter monogram fallback used when the server has no icon set.
    /// Mirrors Discord's own treatment — split the name on whitespace and
    /// take the first letter of the first two tokens.
    var initials: String {
        let pieces = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
        let initials = pieces.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    /// Deep link to open this server in Discord's web client. Used by the
    /// launcher's "Open in Discord" CTA so the user can fall through to the
    /// real client for actual messaging.
    var webURL: URL? {
        URL(string: "https://discord.com/channels/\(id)")
    }
}
