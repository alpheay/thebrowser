import Foundation
import Testing
@testable import TheBrowser

@Suite("ScratchDirectory")
struct ScratchDirectoryTests {
    @Test("Window paths are deterministic across instances")
    func pathDeterminism() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { cleanup(suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheBrowserTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = ScratchDirectory(defaults: defaults, applicationSupportDirectory: root)
        let second = ScratchDirectory(defaults: defaults, applicationSupportDirectory: root)

        #expect(first.url(forWindow: "window-a") == second.url(forWindow: "window-a"))
        #expect(first.url(forWindow: "window-a").lastPathComponent.hasPrefix("win-"))
        #expect(first.url(forWindow: "window-a") != first.url(forWindow: "window-b"))
    }

    @Test("Directory is created when writing a file")
    func createOnWrite() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { cleanup(suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheBrowserTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scratch = ScratchDirectory(defaults: defaults, applicationSupportDirectory: root)
        let directory = scratch.url(forWindow: "window-a")
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let file = try scratch.write(Data("hello".utf8), to: "nested/test.md", forWindow: "window-a")
        let contents = try String(contentsOf: file, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(contents == "hello")
        #expect(file.path.hasPrefix(directory.path + "/"))
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "TheBrowserScratchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    private func cleanup(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}
