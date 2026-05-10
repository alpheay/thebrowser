import Foundation
import Testing
@testable import TheBrowser

@MainActor
@Suite("Google OAuth redirect URI derivation")
struct GoogleAuthRedirectURITests {
    @Test("Reverses the client ID prefix and adds the /oauth2redirect path")
    func standardClientID() throws {
        let service = GoogleAuthService(clientID: "123456789-abcdef.apps.googleusercontent.com")
        #expect(try service.redirectURI == "com.googleusercontent.apps.123456789-abcdef:/oauth2redirect")
    }

    @Test("Callback URL scheme is the reverse client ID without the path")
    func callbackScheme() throws {
        let service = GoogleAuthService(clientID: "abc-xyz.apps.googleusercontent.com")
        #expect(try service.callbackURLScheme == "com.googleusercontent.apps.abc-xyz")
    }

    @Test("Throws malformedClientID for IDs missing the apps.googleusercontent.com suffix")
    func malformedClientID() {
        let service = GoogleAuthService(clientID: "abc-xyz")
        #expect(throws: GoogleAuthError.self) {
            _ = try service.redirectURI
        }
    }
}

@Suite("PKCE challenge")
struct PKCEChallengeTests {
    @Test("Code challenge for the RFC 7636 sample verifier matches the spec")
    func rfc7636Vector() {
        // From RFC 7636 §4.4: verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        // → challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Verifier uses the unreserved character set and reaches the requested length")
    func verifierShape() {
        let verifier = PKCE.codeVerifier()
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(verifier.count == 64)
        #expect(verifier.allSatisfy { allowed.contains($0) })
    }
}

@Suite("Google profile decoding")
struct GoogleProfileDecodingTests {
    @Test("Decodes a typical userinfo response into a profile")
    func decodesFullPayload() throws {
        let json = """
        {
          "sub": "10987654321",
          "email": "ada@example.com",
          "email_verified": true,
          "name": "Ada Lovelace",
          "picture": "https://lh3.googleusercontent.com/a/photo"
        }
        """
        let profile = try JSONDecoder().decode(GoogleProfile.self, from: Data(json.utf8))
        #expect(profile.subject == "10987654321")
        #expect(profile.email == "ada@example.com")
        #expect(profile.name == "Ada Lovelace")
        #expect(profile.pictureURL == "https://lh3.googleusercontent.com/a/photo")
        #expect(profile.verifiedEmail == true)
    }

    @Test("Tolerates a missing email_verified field by defaulting to false")
    func defaultsUnverifiedWhenAbsent() throws {
        let json = """
        { "sub": "1", "email": "a@b.co" }
        """
        let profile = try JSONDecoder().decode(GoogleProfile.self, from: Data(json.utf8))
        #expect(profile.verifiedEmail == false)
        #expect(profile.name == nil)
    }

    @Test("Display name falls back to email when name is missing or empty")
    func displayNameFallback() {
        let withName = GoogleProfile(subject: "1", email: "a@b.co", name: "Grace Hopper", pictureURL: nil, verifiedEmail: true)
        let noName = GoogleProfile(subject: "1", email: "a@b.co", name: nil, pictureURL: nil, verifiedEmail: false)
        #expect(withName.displayName == "Grace Hopper")
        #expect(noName.displayName == "a@b.co")
    }

    @Test("Initials produce two uppercase letters from the first two name words")
    func initialsFromName() {
        let profile = GoogleProfile(subject: "1", email: "x@y.z", name: "ada lovelace", pictureURL: nil, verifiedEmail: false)
        #expect(profile.initials == "AL")
    }
}
