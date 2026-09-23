import Observation
import SwiftUI
import AVFoundation

enum ChatFeatureSheet: Identifiable {
    case task(GuidedTask, String, append: Bool = false)
    case library, preferences, scan, about
    case edit(ChatMessage)

    var id: String {
        switch self {
        case let .task(task, _, _): return "task-" + task.rawValue
        case .library: return "library"
        case .preferences: return "preferences"
        case .scan: return "scan"
        case .about: return "about"
        case let .edit(message): return "edit-" + message.id
        }
    }
}

struct ChatTranscriptDestination: Equatable {
    let conversationID: UUID
    let messageID: String
    let requestID = UUID()
}

@MainActor @Observable
final class ChatFeatureCoordinator {
    var sheet: ChatFeatureSheet?
    var queuedSheet: ChatFeatureSheet?
    var destination: ChatTranscriptDestination?
    var error: String?
    var queuedError: String?
    var offersCameraSettings = false
    let library = ChatLibraryStore()
    let speech = ChatSpeechReader()
}

private struct ChatFeaturesKey: EnvironmentKey {
    static let defaultValue: ChatFeatureCoordinator? = nil
}

private struct ChatConversationIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var chatFeatures: ChatFeatureCoordinator? {
        get { self[ChatFeaturesKey.self] }
        set { self[ChatFeaturesKey.self] = newValue }
    }
    var chatConversationID: UUID? {
        get { self[ChatConversationIDKey.self] }
        set { self[ChatConversationIDKey.self] = newValue }
    }
}

struct ChatFeatureMenu: View {
    let features: ChatFeatureCoordinator
    let draft: String
    let conversationID: UUID?
    var canChangeDraft = true

    var body: some View {
        Menu {
            Section("Start with a task") {
                ForEach(GuidedTask.allCases) { task in
                    Button(task.title, systemImage: task.symbol) { features.sheet = .task(task, draft) }
                        .disabled(!canChangeDraft)
                }
                if ScanTextSheet.isSupported {
                    Button("Scan text", systemImage: "doc.text.viewfinder") {
                        switch AVCaptureDevice.authorizationStatus(for: .video) {
                        case .denied:
                            features.offersCameraSettings = true
                            features.error = "Allow Camera access for Yemma in Settings to scan text."
                        case .restricted:
                            features.error = "Camera access is restricted on this device."
                        default:
                            features.sheet = .scan
                        }
                    }
                        .disabled(!canChangeDraft)
                }
            }
            Section {
                Button("Search chats and saved answers", systemImage: "magnifyingglass") { features.sheet = .library }
                if let conversationID {
                    Button(features.library.pinnedIDs.contains(conversationID) ? "Unpin chat" : "Pin chat", systemImage: "pin") {
                        features.library.togglePin(conversationID)
                    }
                }
            }
            if features.speech.isSpeaking {
                Button("Stop reading", systemImage: "stop.circle") { features.speech.stop() }
            }
            Button("Preferences and privacy", systemImage: "slider.horizontal.3") { features.sheet = .preferences }
            Button("About Yemma", systemImage: "info.circle") { features.sheet = .about }
        } label: {
            Label("Chat tools", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("chatTools")
    }
}

struct ChatFeaturePresentation: ViewModifier {
    @Bindable var features: ChatFeatureCoordinator
    @Binding var draft: String
    let onSelectConversation: (UUID, String?) -> Void
    let onCreateRevision: (ChatMessage, String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $features.sheet, onDismiss: {
                if let message = features.queuedError {
                    features.queuedError = nil
                    features.error = message
                }
                if let next = features.queuedSheet {
                    features.queuedSheet = nil
                    features.sheet = next
                }
            }) { sheet in
                switch sheet {
                case let .task(task, input, append):
                    TaskInputSheet(task: task, initialText: input) { prompt in
                        if append && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            draft += "\n\n" + prompt
                        } else {
                            draft = prompt
                        }
                    }
                case .library:
                    ChatLibrarySheet(library: features.library, onSelect: onSelectConversation)
                case .preferences:
                    PersonalPreferencesSheet()
                case .about:
                    AboutYemmaSheet()
                case let .edit(message):
                    EditPromptSheet(message: message) { onCreateRevision(message, $0) }
                case .scan:
                    ScanTextSheet(onRecognizedText: { text in
                        features.queuedSheet = .task(.summarize, text, append: true)
                        features.sheet = nil
                    }, onCancel: {
                        features.sheet = nil
                    }, onFailure: { message in
                        features.queuedError = message
                        features.sheet = nil
                    })
                }
            }
            .alert("Could not finish", isPresented: Binding(
                get: { features.error != nil },
                set: { if !$0 { features.error = nil; features.offersCameraSettings = false } }
            )) {
                if features.offersCameraSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("OK", role: .cancel) { features.error = nil }
            } message: {
                Text(features.error ?? "Please try again.")
            }
    }
}
