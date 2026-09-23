import Foundation
import Observation

/// Stores references only. Deleting a conversation also removes its saved answers.
@MainActor @Observable
final class ChatLibraryStore {
    struct SavedAnswer: Codable, Hashable {
        let conversationID: UUID
        let messageID: String
    }

    private(set) var pinnedIDs: Set<UUID>
    private(set) var savedAnswers: Set<SavedAnswer>
    @ObservationIgnored private let defaults: UserDefaults
    private static let pinsKey = "chatLibrary.pins"
    private static let answersKey = "chatLibrary.answers"

    init(defaults: UserDefaults = PersonalPreferences.defaults) {
        self.defaults = defaults
        pinnedIDs = Set((defaults.stringArray(forKey: Self.pinsKey) ?? []).compactMap(UUID.init(uuidString:)))
        savedAnswers = defaults.data(forKey: Self.answersKey)
            .flatMap { try? JSONDecoder().decode(Set<SavedAnswer>.self, from: $0) } ?? []
    }

    func togglePin(_ id: UUID) {
        if !pinnedIDs.insert(id).inserted { pinnedIDs.remove(id) }
        persist()
    }

    func isSaved(conversationID: UUID, messageID: String) -> Bool {
        savedAnswers.contains(SavedAnswer(conversationID: conversationID, messageID: messageID))
    }

    func toggleSaved(conversationID: UUID, messageID: String) {
        let answer = SavedAnswer(conversationID: conversationID, messageID: messageID)
        if !savedAnswers.insert(answer).inserted { savedAnswers.remove(answer) }
        persist()
    }

    func prune(conversationIDs: Set<UUID>) {
        pinnedIDs.formIntersection(conversationIDs)
        savedAnswers = savedAnswers.filter { conversationIDs.contains($0.conversationID) }
        persist()
    }

    private func persist() {
        defaults.set(pinnedIDs.map(\.uuidString).sorted(), forKey: Self.pinsKey)
        if let data = try? JSONEncoder().encode(savedAnswers) {
            defaults.set(data, forKey: Self.answersKey)
        }
    }
}

struct ChatSearchResult: Identifiable {
    let conversationID: UUID
    let messageID: String?
    let title: String
    let excerpt: String
    var id: String { conversationID.uuidString + ":" + (messageID ?? "title") }

    static func excerpt(from text: String, matching query: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        guard !query.isEmpty, let range = clean.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(clean.prefix(180))
        }
        let start = clean.index(range.lowerBound, offsetBy: -45, limitedBy: clean.startIndex) ?? clean.startIndex
        let end = clean.index(range.upperBound, offsetBy: 130, limitedBy: clean.endIndex) ?? clean.endIndex
        return (start > clean.startIndex ? "…" : "") + clean[start..<end] + (end < clean.endIndex ? "…" : "")
    }
}
