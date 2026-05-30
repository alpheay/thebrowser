import Foundation
@preconcurrency import WebKit

/// Small async wrapper around WebKit's website-data deletion API.
@MainActor
enum WebsiteDataCleaner {
    static func clearAll() async {
        await clear(types: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    static func clear(types: Set<String>, modifiedSince date: Date) async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: date) {
                continuation.resume()
            }
        }
    }
}
