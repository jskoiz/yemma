import SwiftUI

public enum Yemma4AppConfiguration {
    public static let bundleIdentifier = "com.avmillabs.yemma4"
}

@main
public struct Yemma4App: App {
    @State private var modelDownloader = ModelDownloader()
    @State private var llmService = LLMService()

    public static let bundleIdentifier = Yemma4AppConfiguration.bundleIdentifier

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(modelDownloader)
                .environment(llmService)
        }
    }
}
