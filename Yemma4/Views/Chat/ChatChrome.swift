import SwiftUI

struct ChatToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(AppTheme.accentForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppTheme.toastFill)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
            .shadow(color: AppTheme.toastShadow, radius: 18, x: 0, y: 10)
            .padding(.horizontal, 24)
    }
}
