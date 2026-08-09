import Foundation
import Observation
import os

#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.metadata = metadata
    }

    static func merged(
        _ persistedEvents: [DiagnosticEvent],
        with currentEvents: [DiagnosticEvent],
        limit: Int
    ) -> [DiagnosticEvent] {
        var seenIDs = Set<UUID>()
        let merged = (persistedEvents + currentEvents).filter { event in
            seenIDs.insert(event.id).inserted
        }
        guard merged.count > limit else { return merged }
        return Array(merged.suffix(limit))
    }
}

enum DebugPreferences {
    static let showsAssistantResponseStatsKey = "com.avmillabs.yemma4.debug.showsAssistantResponseStats"
}

@Observable
final class AppDiagnostics: @unchecked Sendable {
    static let shared = AppDiagnostics()

    private(set) var recentEvents: [DiagnosticEvent] = []

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let maxEvents = 120
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let logger = Logger(subsystem: Yemma4AppConfiguration.bundleIdentifier, category: "Diagnostics")
    @ObservationIgnored private let writer: DiagnosticsWriter
    @ObservationIgnored private var hasLoadedPersistedEvents = false
    @ObservationIgnored private var isLoadingPersistedEvents = false
    @ObservationIgnored private var activeLoadID: UUID?
    @ObservationIgnored private var persistenceRevision: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        writer: DiagnosticsWriter? = nil,
        storageKey: String = "com.avmillabs.yemma4.diagnostics.events"
    ) {
        self.writer = writer ?? DiagnosticsWriter(defaults: defaults)
        self.storageKey = storageKey
    }

    func record(
        _ message: String,
        category: String,
        metadata: [String: CustomStringConvertible] = [:]
    ) {
        let normalizedMetadata = metadata.reduce(into: [String: String]()) { result, item in
            result[item.key] = String(describing: item.value)
        }
        let event = DiagnosticEvent(category: category, message: message, metadata: normalizedMetadata)

        let persistenceRequest = withLock { () -> (events: [DiagnosticEvent], revision: UInt64) in
            var updated = recentEvents
            updated.append(event)
            if updated.count > maxEvents {
                updated.removeFirst(updated.count - maxEvents)
            }
            recentEvents = updated
            persistenceRevision &+= 1
            return (updated, persistenceRevision)
        }

        persist(persistenceRequest.events, revision: persistenceRequest.revision)
        let metadataText = normalizedMetadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        if metadataText.isEmpty {
            logger.log("\(category, privacy: .public): \(message, privacy: .public)")
        } else {
            // Metadata values can carry user-derived strings; redact them from the
            // system log so raw content never reaches sysdiagnose/Console in cleartext.
            logger.log("\(category, privacy: .public): \(message, privacy: .public) [\(metadataText, privacy: .private)]")
        }
    }

    func clear() async {
        let revision = withLock { () -> UInt64 in
            recentEvents = []
            persistenceRevision &+= 1
            // A clear is authoritative for this process. Mark startup loading
            // complete so a delayed read cannot restore the data just cleared.
            hasLoadedPersistedEvents = true
            isLoadingPersistedEvents = false
            activeLoadID = nil
            return persistenceRevision
        }
        await writer.clear(storageKey: storageKey, revision: revision)
        logger.log("diagnostics: cleared")
    }

    func snapshot() -> [DiagnosticEvent] {
        withLock { recentEvents }
    }

    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        let events = withLock { recentEvents }
        return events.map { event in
            let metadataSuffix: String
            if event.metadata.isEmpty {
                metadataSuffix = ""
            } else {
                let pairs = event.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", ")
                metadataSuffix = " [\(pairs)]"
            }

            return "\(formatter.string(from: event.timestamp)) \(event.category): \(event.message)\(metadataSuffix)"
        }
        .joined(separator: "\n")
    }

    func copyToPasteboard() {
#if canImport(UIKit)
        UIPasteboard.general.string = exportText()
#endif
    }

    func loadPersistedEventsIfNeeded() async {
        let loadID = withLock { () -> UUID? in
            guard !hasLoadedPersistedEvents, !isLoadingPersistedEvents else { return nil }
            let loadID = UUID()
            isLoadingPersistedEvents = true
            activeLoadID = loadID
            return loadID
        }
        guard let loadID else { return }

        let persistedEvents = await writer.events(
            storageKey: storageKey,
            maxEvents: maxEvents
        )

        let persistenceRequest = await MainActor.run {
            withLock { () -> (events: [DiagnosticEvent], revision: UInt64)? in
                guard activeLoadID == loadID else { return nil }

                recentEvents = DiagnosticEvent.merged(
                    persistedEvents,
                    with: recentEvents,
                    limit: maxEvents
                )
                persistenceRevision &+= 1
                hasLoadedPersistedEvents = true
                isLoadingPersistedEvents = false
                activeLoadID = nil
                return (recentEvents, persistenceRevision)
            }
        }

        guard let persistenceRequest else { return }
        await writer.write(
            events: persistenceRequest.events,
            storageKey: storageKey,
            revision: persistenceRequest.revision,
            maxEvents: maxEvents
        )
    }

    private func persist(_ events: [DiagnosticEvent], revision: UInt64) {
        let key = self.storageKey
        let writer = self.writer
        let eventLimit = self.maxEvents
        Task.detached(priority: .utility) {
            await writer.write(
                events: events,
                storageKey: key,
                revision: revision,
                maxEvents: eventLimit
            )
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

}

/// Serial writer actor that keeps UserDefaults I/O off the caller's thread.
actor DiagnosticsWriter {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let beforeInitialRead: (@Sendable () async -> Void)?
    private var latestRevisionByStorageKey: [String: UInt64] = [:]
    private var cachedEventsByStorageKey: [String: [DiagnosticEvent]] = [:]

    init(
        defaults: UserDefaults = .standard,
        beforeInitialRead: (@Sendable () async -> Void)? = nil
    ) {
        self.defaults = defaults
        self.beforeInitialRead = beforeInitialRead
    }

    func events(storageKey: String, maxEvents: Int = 120) async -> [DiagnosticEvent] {
        if let cachedEvents = cachedEventsByStorageKey[storageKey] {
            return cachedEvents
        }

        await beforeInitialRead?()
        if let cachedEvents = cachedEventsByStorageKey[storageKey] {
            return cachedEvents
        }

        let decoded: [DiagnosticEvent]
        if let data = defaults.data(forKey: storageKey),
           let storedEvents = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) {
            decoded = Array(storedEvents.suffix(maxEvents))
        } else {
            decoded = []
        }
        cachedEventsByStorageKey[storageKey] = decoded
        return decoded
    }

    func write(
        events: [DiagnosticEvent],
        storageKey: String,
        revision: UInt64,
        maxEvents: Int = 120
    ) async {
        guard revision >= latestRevisionByStorageKey[storageKey, default: 0] else { return }
        let persistedEvents = await self.events(storageKey: storageKey, maxEvents: maxEvents)
        guard revision >= latestRevisionByStorageKey[storageKey, default: 0] else { return }
        let mergedEvents = DiagnosticEvent.merged(
            persistedEvents,
            with: events,
            limit: maxEvents
        )
        guard let data = try? encoder.encode(mergedEvents) else { return }

        latestRevisionByStorageKey[storageKey] = revision
        cachedEventsByStorageKey[storageKey] = mergedEvents
        defaults.set(data, forKey: storageKey)
    }

    func clear(storageKey: String, revision: UInt64) {
        guard revision >= latestRevisionByStorageKey[storageKey, default: 0] else { return }

        latestRevisionByStorageKey[storageKey] = revision
        cachedEventsByStorageKey[storageKey] = []
        defaults.removeObject(forKey: storageKey)
    }
}
