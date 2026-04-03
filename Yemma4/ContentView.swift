import SwiftUI

public struct ContentView: View {
    @State private var modelDownloader = ModelDownloader()

    public init() {}

    public var body: some View {
        ZStack {
            if modelDownloader.isDownloaded {
                ChatView()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                OnboardingView(modelDownloader: modelDownloader)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: modelDownloader.isDownloaded)
    }
}
