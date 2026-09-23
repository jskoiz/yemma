import SwiftUI

struct ChatLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConversationStore.self) private var conversations
    let library: ChatLibraryStore
    let onSelect: (UUID, String?) -> Void
    @State private var query = ""
    @State private var savedOnly = false
    @State private var results: [ChatSearchResult] = []
    @State private var isSearching = false
    @State private var unreadableCount = 0
    @State private var reachedResultLimit = false
    private let resultLimit = 200

    private var requestID: String {
        query + "|" + String(savedOnly) + "|" + String(library.savedAnswers.hashValue)
            + "|" + String(conversations.conversations.hashValue)
            + "|" + String(library.pinnedIDs.hashValue)
    }

    var body: some View {
        NavigationStack {
            List {
                Toggle("Saved answers only", isOn: $savedOnly)
                if isSearching {
                    ProgressView("Searching on this iPhone…")
                } else if results.isEmpty {
                    Text(savedOnly ? "Save an answer from its message menu to find it here." : "No matching chats.")
                        .foregroundStyle(.secondary)
                }
                if unreadableCount > 0 {
                    Text("Some chats could not be searched. Their files have been kept.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if reachedResultLimit {
                    Text("Showing the first 200 results. Narrow your search to find a specific message.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(sortedResults) { result in
                    Button {
                        onSelect(result.conversationID, result.messageID)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(result.title).font(.headline)
                                if library.pinnedIDs.contains(result.conversationID) {
                                    Image(systemName: "pin.fill").accessibilityLabel("Pinned")
                                }
                            }
                            Text(result.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Button(library.pinnedIDs.contains(result.conversationID) ? "Unpin chat" : "Pin chat", systemImage: "pin") {
                            library.togglePin(result.conversationID)
                        }
                        if savedOnly, let messageID = result.messageID {
                            Button("Remove saved answer", systemImage: "bookmark.slash") {
                                library.toggleSaved(conversationID: result.conversationID, messageID: messageID)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chat library")
            .searchable(text: $query, prompt: "Search all messages")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: requestID) { await search() }
        }
    }

    private var sortedResults: [ChatSearchResult] {
        // Stable order within each group preserves conversation recency.
        results.filter { library.pinnedIDs.contains($0.conversationID) }
            + results.filter { !library.pinnedIDs.contains($0.conversationID) }
    }

    @MainActor private func search() async {
        isSearching = true
        results = []
        unreadableCount = 0
        reachedResultLimit = false
        do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
        await conversations.loadIndexIfNeeded()
        guard !Task.isCancelled else { return }
        library.prune(conversationIDs: Set(conversations.conversations.map(\.id)))
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [ChatSearchResult] = []
        var failures = 0
        var limited = false
        let all = conversations.conversations
        let ordered = all.filter { library.pinnedIDs.contains($0.id) } + all.filter { !library.pinnedIDs.contains($0.id) }
        conversationLoop: for metadata in ordered {
            guard !Task.isCancelled else { return }
            if found.count >= resultLimit { limited = true; break }
            if term.isEmpty && !savedOnly {
                found.append(ChatSearchResult(conversationID: metadata.id, messageID: nil, title: metadata.title, excerpt: metadata.preview))
                continue
            }
            guard let snapshot = await conversations.loadConversationAsync(id: metadata.id) else {
                failures += 1
                continue
            }
            guard !Task.isCancelled else { return }
            var matchedMessage = false
            for message in snapshot.messages {
                if found.count >= resultLimit { limited = true; break conversationLoop }
                if savedOnly && !library.isSaved(conversationID: metadata.id, messageID: message.id) { continue }
                guard term.isEmpty || message.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
                matchedMessage = true
                found.append(ChatSearchResult(conversationID: metadata.id, messageID: message.id, title: metadata.title,
                    excerpt: ChatSearchResult.excerpt(from: message.text, matching: term)))
            }
            if !savedOnly && !matchedMessage && metadata.title.localizedStandardContains(term) {
                found.append(ChatSearchResult(conversationID: metadata.id, messageID: nil, title: metadata.title, excerpt: metadata.preview))
            }
        }
        guard !Task.isCancelled else { return }
        results = found
        unreadableCount = failures
        reachedResultLimit = limited
        isSearching = false
    }
}
