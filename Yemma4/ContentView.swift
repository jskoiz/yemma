import SwiftUI

public struct ContentView: View {
    @State private var isShowingChat = false

    public init() {}

    public var body: some View {
        Group {
            if isShowingChat {
                ChatView()
            } else {
                OnboardingView {
                    isShowingChat = true
                }
            }
        }
    }
}
