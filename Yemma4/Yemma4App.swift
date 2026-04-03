import SwiftUI

public enum Yemma4AppConfiguration {
    public static let bundleIdentifier = "com.jskoiz.yemma4"
}

public struct Yemma4App: View {
    @State private var modelDownloader = ModelDownloader()
    @State private var llmService = LLMService()

    public static let bundleIdentifier = Yemma4AppConfiguration.bundleIdentifier

    public init() {}

    public var body: some View {
        ContentView()
            .environment(modelDownloader)
            .environment(llmService)
    }
}
