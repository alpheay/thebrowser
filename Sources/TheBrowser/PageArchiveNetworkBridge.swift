import Foundation
@preconcurrency import WebKit

/// JS -> Swift bridge for best-effort page network observations.
///
/// This is intentionally not a HAR bridge: WebKit does not expose one.
/// The injected script sees fetch/XHR it wraps and some Resource Timing
/// entries, but it cannot see websockets, `sendBeacon`, service-worker
/// requests that beat script installation, or subresources fetched before
/// `WKUserScript` runs.
final class PageArchiveNetworkBridge: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    static let messageName = "thebrowserPageArchiveNetwork"

    static var userScript: WKUserScript {
        WKUserScript(
            source: scriptSource(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName else { return }
        let events = Self.events(from: message.body)
        guard !events.isEmpty else { return }

        Task { @MainActor [weak tab] in
            tab?.recordArchiveNetworkEvents(events)
        }
    }

    private static func scriptSource() -> String {
        guard let url = Bundle.module.url(forResource: "NetworkLogScript", withExtension: "js"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return template.replacingOccurrences(of: "__THEBROWSER_NETWORK_HANDLER__", with: messageName)
    }

    private static func events(from body: Any) -> [PageArchiveNetworkEvent] {
        let rawItems: [Any]
        if let dictionary = body as? [String: Any], let events = dictionary["events"] as? [Any] {
            rawItems = events
        } else if let events = body as? [Any] {
            rawItems = events
        } else {
            rawItems = []
        }

        return rawItems.compactMap { item in
            guard let dictionary = item as? [String: Any] else { return nil }
            return event(from: dictionary)
        }
    }

    private static func event(from dictionary: [String: Any]) -> PageArchiveNetworkEvent? {
        guard let url = stringValue(dictionary["url"]), !url.isEmpty else { return nil }

        let timestamp: Date
        if let milliseconds = numberValue(dictionary["ts"])?.doubleValue {
            timestamp = Date(timeIntervalSince1970: milliseconds / 1000.0)
        } else {
            timestamp = Date()
        }

        let status = numberValue(dictionary["status"])?.intValue
        let duration = numberValue(dictionary["durationMs"])?.doubleValue
        let method = stringValue(dictionary["method"])?.uppercased() ?? "GET"
        let type = stringValue(dictionary["type"]) ?? stringValue(dictionary["source"]) ?? ""

        return PageArchiveNetworkEvent(
            timestamp: timestamp,
            pageURL: stringValue(dictionary["pageURL"]),
            method: method,
            url: url,
            status: status,
            type: type,
            requestHeaders: headers(from: dictionary["requestHeaders"]),
            responseHeaders: headers(from: dictionary["responseHeaders"]),
            requestBody: stringValue(dictionary["requestBody"]),
            responseBody: stringValue(dictionary["responseBody"]),
            durationMS: duration
        )
    }

    private static func headers(from value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in dictionary {
            headers[key] = String(describing: value)
        }
        return headers
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let string = value as? String, let double = Double(string) {
            return NSNumber(value: double)
        }
        return nil
    }
}
