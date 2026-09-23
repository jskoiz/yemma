import SwiftUI

struct ChatTopBar: View {
    let onToggleSidebar: () -> Void
    let onStartFresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CircleIconButton(
                systemName: "line.3.horizontal",
                filled: true,
                action: onToggleSidebar
            )
            .accessibilityLabel("Open sidebar")
            .accessibilityHint("Browse saved chats and quick settings.")

            Spacer(minLength: 0)

            CircleIconButton(systemName: "square.and.pencil", action: onStartFresh)
            .accessibilityLabel("New chat")
            .accessibilityHint("Start a fresh conversation and keep older chats saved.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}

struct ChatToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.accentForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppTheme.toastFill)
            .clipShape(Capsule())
            .shadow(color: AppTheme.toastShadow, radius: 18, x: 0, y: 10)
            .padding(.horizontal, 24)
    }
}
