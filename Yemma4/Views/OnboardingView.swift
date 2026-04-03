import SwiftUI

public struct OnboardingView: View {
    private let onContinue: () -> Void

    public init(onContinue: @escaping () -> Void = {}) {
        self.onContinue = onContinue
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Yemma 4")
                .font(.largeTitle.bold())
            Text("Private, on-device chat scaffold.")
                .foregroundStyle(.secondary)

            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
