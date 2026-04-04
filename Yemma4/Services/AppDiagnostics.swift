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

@Observable
final class AppDiagnostics: @unchecked Sendable {
    static let shared = AppDiagnostics()

    private(set) var recentEvents: [DiagnosticEvent] = []

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let maxEvents = 120
    @ObservationIgnored private let storageKey = "com.avmillabs.yemma4.diagnostics.events"
    @ObservationIgnored private let logger = Logger(subsystem: Yemma4AppConfiguration.bundleIdentifier, category: "Diagnostics")
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    private init() {
        loadPersistedEvents()
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

        let snapshot = withLock { () -> [DiagnosticEvent] in
            var updated = recentEvents
            updated.append(event)
            if updated.count > maxEvents {
                updated.removeFirst(updated.count - maxEvents)
            }
            recentEvents = updated
            return updated
        }

        persist(snapshot)
        let metadataText = normalizedMetadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        if metadataText.isEmpty {
            logger.log("\(category, privacy: .public): \(message, privacy: .public)")
        } else {
            logger.log("\(category, privacy: .public): \(message, privacy: .public) [\(metadataText, privacy: .public)]")
        }
    }

    func clear() {
        withLock {
            recentEvents = []
        }
        UserDefaults.standard.removeObject(forKey: storageKey)
        logger.log("diagnostics: cleared")
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

    private func loadPersistedEvents() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        guard let decoded = try? decoder.decode([DiagnosticEvent].self, from: data) else { return }
        recentEvents = decoded
    }

    private func persist(_ events: [DiagnosticEvent]) {
        let encoder = self.encoder
        let key = self.storageKey
        Task.detached(priority: .utility) {
            await DiagnosticsWriter.shared.write(events: events, encoder: encoder, storageKey: key)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Serial writer actor that keeps UserDefaults I/O off the caller's thread.
private actor DiagnosticsWriter {
    static let shared = DiagnosticsWriter()

    func write(events: [DiagnosticEvent], encoder: JSONEncoder, storageKey: String) {
        guard let data = try? encoder.encode(events) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
