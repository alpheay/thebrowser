import Foundation
import SwiftData

actor ThreadStore {
    static let shared: ThreadStore = {
        do {
            return try ThreadStore()
        } catch {
            fatalError("Failed to create ThreadStore: \(error)")
        }
    }()

    private let container: ModelContainer
    private let context: ModelContext
    private let scratchRoot: URL

    init(
        inMemory: Bool = false,
        scratchRoot: URL = ThreadScratchDirectory.rootURL
    ) throws {
        let schema = Schema([Thread.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        self.container = try ModelContainer(for: schema, configurations: [configuration])
        self.context = ModelContext(container)
        self.scratchRoot = scratchRoot
    }

    init(container: ModelContainer, scratchRoot: URL = ThreadScratchDirectory.rootURL) {
        self.container = container
        self.context = ModelContext(container)
        self.scratchRoot = scratchRoot
    }

    func list() throws -> [ThreadRecord] {
        var descriptor = FetchDescriptor<Thread>(
            predicate: #Predicate { thread in
                !thread.isArchived
            },
            sortBy: [SortDescriptor(\.lastFocusedAt, order: .reverse)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).map(ThreadRecord.init(thread:))
    }

    func create(
        title: String? = nil,
        tabs: [TabSnapshot] = [],
        agentContext: String = "",
        isWindowOpen: Bool = false
    ) throws -> ThreadRecord {
        let id = UUID()
        let generatedTitle = title ?? Thread.generatedTitle(from: tabs)
        let thread = Thread(
            id: id,
            title: generatedTitle,
            tabs: tabs,
            agentContext: agentContext,
            scratchDirPath: scratchURL(for: id).path,
            isWindowOpen: isWindowOpen
        )
        ensureScratchDirectory(for: thread)
        context.insert(thread)
        try context.save()
        return ThreadRecord(thread: thread)
    }

    func get(id: UUID) throws -> ThreadRecord? {
        guard let thread = try fetchThread(id: id) else { return nil }
        thread.lastFocusedAt = Date()
        try context.save()
        return ThreadRecord(thread: thread)
    }

    func updateTabs(id: UUID, tabs: [TabSnapshot]) throws -> ThreadRecord? {
        guard let thread = try fetchThread(id: id) else { return nil }
        thread.tabs = tabs
        thread.lastFocusedAt = Date()
        thread.title = Thread.generatedTitle(from: tabs, fallback: thread.title)
        ensureScratchDirectory(for: thread)
        try context.save()
        return ThreadRecord(thread: thread)
    }

    func updateAgentContext(id: UUID, agentContext: String) throws -> ThreadRecord? {
        guard let thread = try fetchThread(id: id) else { return nil }
        thread.agentContext = agentContext
        thread.lastFocusedAt = Date()
        try context.save()
        return ThreadRecord(thread: thread)
    }

    func markWindowOpen(id: UUID, isOpen: Bool) throws -> ThreadRecord? {
        guard let thread = try fetchThread(id: id) else { return nil }
        thread.isWindowOpen = isOpen
        if isOpen {
            thread.lastFocusedAt = Date()
        }
        try context.save()
        return ThreadRecord(thread: thread)
    }

    func archive(id: UUID) throws {
        guard let thread = try fetchThread(id: id) else { return }
        thread.isArchived = true
        thread.isWindowOpen = false
        try context.save()
    }

    func delete(id: UUID) throws {
        guard let thread = try fetchThread(id: id) else { return }
        let scratchPath = thread.scratchDirPath
        context.delete(thread)
        try context.save()

        if !scratchPath.isEmpty {
            try? FileManager.default.removeItem(atPath: scratchPath)
        }
    }

    private func fetchThread(id: UUID) throws -> Thread? {
        var descriptor = FetchDescriptor<Thread>(
            predicate: #Predicate { thread in
                thread.id == id
            }
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    private func scratchURL(for id: UUID) -> URL {
        scratchRoot
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("scratch", isDirectory: true)
    }

    private func ensureScratchDirectory(for thread: Thread) {
        guard !thread.scratchDirPath.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: thread.scratchDirPath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}
