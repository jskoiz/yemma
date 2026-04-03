import SwiftUI

public struct ChatView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Text("Yemma 4")
                .font(.title2.weight(.semibold))
            Text("Chat UI scaffold placeholder.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
