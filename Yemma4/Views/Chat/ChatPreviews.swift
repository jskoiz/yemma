import SwiftUI

// MARK: - Preview helpers

extension ChatMessage {
    static func previewMessage(user: User, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            user: user,
            status: .sent,
            createdAt: .now,
            text: text,
            attachments: []
        )
    }
}

#if DEBUG
private let previewConversationID = UUID()

@MainActor
private func previewChatStore(
    currentConversationID: UUID = previewConversationID,
    title: String,
    messages: [ChatMessage],
    draftText: String = ""
) -> ConversationStore {
    ConversationStore.preview(
        currentConversationID: currentConversationID,
        conversations: [
            ConversationSnapshot(
                id: currentConversationID,
                title: title,
                messages: messages,
                draftText: draftText,
                draftAttachments: []
            )
        ]
    )
}

private extension LLMService {
    static func previewLoaded() -> LLMService {
        let service = LLMService()
        service.isModelLoaded = true
        return service
    }

    static func previewWarmShell() -> LLMService {
        let service = LLMService()
        service.isModelLoading = true
        service.modelLoadStage = .loadingModel
        return service
    }
}

#Preview("Chat") {
    ChatView()
        .environment(LLMService.previewLoaded())
        .environment(ModelDownloader())
        .environment(
            previewChatStore(
                title: "Workout split",
                messages: [
                    .previewMessage(
                        user: .user,
                        text: "Plan me a focused three-day workout split for strength and cardio."
                    ),
                    .previewMessage(
                        user: .yemma,
                        text: "Here is a simple split: Day 1 push and intervals, Day 2 lower body and incline walking, Day 3 pull and steady-state cardio. Keep each session around 45 minutes."
                    ),
                    .previewMessage(
                        user: .user,
                        text: "Keep it beginner friendly and make the gym version optional."
                    )
                ]
            )
        )
}

#Preview("Warm Shell") {
    ChatView()
        .environment(LLMService.previewWarmShell())
        .environment(ModelDownloader())
        .environment(
            previewChatStore(
                title: "New chat",
                messages: [],
                draftText: "Draft a short thank-you note after an interview."
            )
        )
}

#Preview("Chat Dark Compact") {
    ChatView()
        .environment(LLMService.previewLoaded())
        .environment(ModelDownloader())
        .environment(
            previewChatStore(
                title: "Travel plans",
                messages: [
                    .previewMessage(
                        user: .user,
                        text: "Build me a two-day Honolulu itinerary with food, beach time, and one rainy-day backup."
                    ),
                    .previewMessage(
                        user: .yemma,
                        text: "Day 1 can stay centered around Kakaako, Ala Moana, and Waikiki. Day 2 can lean east side with Hanauma Bay timing, a casual lunch, and a museum backup if weather turns."
                    )
                ],
                draftText: "Keep the budget moderate and avoid rental-car-only stops."
            )
        )
        .preferredColorScheme(.dark)
}
#endif
