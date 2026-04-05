import Foundation

/// Stub model store for UI development. Always reports models as downloaded.
@Observable
final class StubAskImageModelStore: AskImageModelStore {
    let availableModels: [LiteRTModelDescriptor] = [
        .gemma4E2B,
        .gemma4E4B,
    ]

    private var states: [String: LiteRTModelState] = [
        LiteRTModelDescriptor.gemma4E2B.id: .downloaded,
        LiteRTModelDescriptor.gemma4E4B.id: .notDownloaded,
    ]

    func state(for modelID: String) -> LiteRTModelState {
        states[modelID] ?? .notDownloaded
    }

    func download(_ model: LiteRTModelDescriptor) async throws {
        states[model.id] = .downloading(progress: 0)
        for i in 1...10 {
            try await Task.sleep(for: .milliseconds(200))
            states[model.id] = .downloading(progress: Double(i) / 10.0)
        }
        states[model.id] = .downloaded
    }

    func cancelDownload(_ modelID: String) {
        states[modelID] = .notDownloaded
    }

    func deleteModel(_ modelID: String) throws {
        states[modelID] = .notDownloaded
    }

    func validate(_ modelID: String) -> Bool {
        state(for: modelID).isDownloaded
    }
}
