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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let writer: DiagnosticsWriter
    @ObservationIgnored private var hasLoadedPersistedEvents = false
    @ObservationIgnored private var isLoadingPersistedEvents = false
    @ObservationIgnored private var persistenceRevision: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        writer: DiagnosticsWriter? = nil,
        storageKey: String = "com.avmillabs.yemma4.diagnostics.events"
    ) {
        self.defaults = defaults
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
        let loadRevision = withLock { () -> UInt64? in
            guard !hasLoadedPersistedEvents, !isLoadingPersistedEvents else { return nil }
            isLoadingPersistedEvents = true
            return persistenceRevision
        }
        guard let loadRevision else { return }

        let storageKey = self.storageKey
        let defaults = self.defaults
        let decoded = await Task.detached(priority: .utility) {
            guard let data = defaults.data(forKey: storageKey) else {
                return [DiagnosticEvent]()
            }
            return (try? JSONDecoder().decode([DiagnosticEvent].self, from: data)) ?? []
        }.value

        await MainActor.run {
            withLock {
                defer {
                    hasLoadedPersistedEvents = true
                    isLoadingPersistedEvents = false
                }
                guard persistenceRevision == loadRevision else { return }
                recentEvents = Self.trimmedEvents(decoded + recentEvents, maxEvents: maxEvents)
            }
        }
    }

    private func persist(_ events: [DiagnosticEvent], revision: UInt64) {
        let key = self.storageKey
        let writer = self.writer
        Task.detached(priority: .utility) {
            await writer.write(
                events: events,
                storageKey: key,
                revision: revision
            )
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func trimmedEvents(_ events: [DiagnosticEvent], maxEvents: Int) -> [DiagnosticEvent] {
        guard events.count > maxEvents else { return events }
        return Array(events.suffix(maxEvents))
    }
}

/// Serial writer actor that keeps UserDefaults I/O off the caller's thread.
actor DiagnosticsWriter {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private var latestRevision: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func write(events: [DiagnosticEvent], storageKey: String, revision: UInt64) {
        guard revision >= latestRevision else { return }
        guard let data = try? encoder.encode(events) else { return }

        latestRevision = revision
        defaults.set(data, forKey: storageKey)
    }

    func clear(storageKey: String, revision: UInt64) {
        guard revision >= latestRevision else { return }

        latestRevision = revision
        defaults.removeObject(forKey: storageKey)
    }
}
