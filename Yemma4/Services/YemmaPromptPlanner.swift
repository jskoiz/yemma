import Foundation
import ExyteChat

enum YemmaPromptPlanner {
    static func promptInput(from message: ChatMessage) -> PromptMessageInput {
        PromptMessageInput(
            role: message.user.isCurrentUser ? "user" : "assistant",
            text: message.text,
            images: message.attachments.compactMap { attachment in
                guard attachment.type == .image, attachment.full.isFileURL else {
                    return nil
                }

                return PromptImageAsset(
                    id: attachment.id,
                    filePath: attachment.full.path
                )
            }
        )
    }

    static func conversationHistory(from messages: [ChatMessage]) -> [PromptMessageInput] {
        messages.compactMap { message in
            let prompt = promptInput(from: message)
            if prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && prompt.images.isEmpty
            {
                return nil
            }
            return prompt
        }
    }
}
