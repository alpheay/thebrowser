import Combine
import Foundation

/// Caches the user's writing-style profile so voice-matched drafts don't
/// rebuild it on every reply. Built once from a sample of Sent mail by
/// `MailAgent.buildVoiceProfile`, persisted under
/// ~/.thebrowser/mail/voice_profile.json, and refreshed only when it ages out.
@MainActor
final class VoiceProfileStore: ObservableObject {
    @Published private(set) var profile: VoiceProfile?
    /// True while a rebuild is in flight, so the UI/tool doesn't kick off a
    /// second concurrent sample+distill.
    @Published private(set) var isBuilding = false

    private static let file = "voice_profile.json"
    /// Rebuild the profile once it's older than this (writing style drifts
    /// slowly; a month is plenty).
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    init() {
        profile = MailStorage.load(VoiceProfile.self, from: Self.file)
    }

    var needsRefresh: Bool {
        guard let profile else { return true }
        return Date().timeIntervalSince(profile.builtAt) > Self.maxAge
    }

    func set(_ profile: VoiceProfile) {
        self.profile = profile
        MailStorage.save(profile, to: Self.file)
    }

    func setBuilding(_ building: Bool) { isBuilding = building }

    func clear() {
        profile = nil
        MailStorage.save(Optional<VoiceProfile>.none, to: Self.file)
    }
}
