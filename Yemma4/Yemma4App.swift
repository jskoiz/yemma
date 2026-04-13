import Darwin
import SwiftUI

public enum StartupTiming {
    private static let context = LaunchContext.capture()

    public static func elapsedMs() -> Int {
        context.elapsedMsSinceProcessStart()
    }

    public static func appCodeElapsedMs() -> Int {
        context.elapsedMsSinceAppCodeEntry()
    }

    public static func launchMetadata() -> [String: CustomStringConvertible] {
        context.metadata
    }

    private struct LaunchContext {
        let appCodeEntryDate: Date
        let processStartDate: Date?
        let debuggerAttached: Bool
        let launchedFromXcode: Bool
        let osActivityDtMode: String
        let pid: Int32

        static func capture() -> Self {
            let pid = getpid()
            let processSnapshot = loadProcessSnapshot(pid: pid)
            let environment = ProcessInfo.processInfo.environment
            let launchedFromXcode =
                processSnapshot.debuggerAttached
                || environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
                || environment["XCTestConfigurationFilePath"] != nil
                || environment["OS_ACTIVITY_DT_MODE"] == "1"
                || environment["OS_ACTIVITY_DT_MODE"] == "YES"

            return Self(
                appCodeEntryDate: Date(),
                processStartDate: processSnapshot.startDate,
                debuggerAttached: processSnapshot.debuggerAttached,
                launchedFromXcode: launchedFromXcode,
                osActivityDtMode: environment["OS_ACTIVITY_DT_MODE"] ?? "unset",
                pid: pid
            )
        }

        func elapsedMsSinceProcessStart() -> Int {
            let origin = processStartDate ?? appCodeEntryDate
            return Int(Date().timeIntervalSince(origin) * 1000)
        }

        func elapsedMsSinceAppCodeEntry() -> Int {
            Int(Date().timeIntervalSince(appCodeEntryDate) * 1000)
        }

        var metadata: [String: CustomStringConvertible] {
            [
                "appCodeElapsedMs": elapsedMsSinceAppCodeEntry(),
                "debuggerAttached": debuggerAttached,
                "launchedFromXcode": launchedFromXcode,
                "osActivityDtMode": osActivityDtMode,
                "pid": pid,
                "timingOrigin": processStartDate == nil ? "app_code_entry" : "process_start"
            ]
        }

        private struct ProcessSnapshot {
            let startDate: Date?
            let debuggerAttached: Bool
        }

        private static func loadProcessSnapshot(pid: Int32) -> ProcessSnapshot {
            var info = kinfo_proc()
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var size = MemoryLayout<kinfo_proc>.stride
            let mibCount = u_int(mib.count)

            let result: Int32 = withUnsafeMutablePointer(to: &info) { infoPointer in
                mib.withUnsafeMutableBufferPointer { mibPointer in
                    infoPointer.withMemoryRebound(to: UInt8.self, capacity: size) { bytes in
                        sysctl(mibPointer.baseAddress, mibCount, bytes, &size, nil, 0)
                    }
                }
            }

            guard result == 0 else {
                return ProcessSnapshot(startDate: nil, debuggerAttached: false)
            }

            let startTime = info.kp_proc.p_starttime
            let startDate = Date(
                timeIntervalSince1970: TimeInterval(startTime.tv_sec)
                    + (TimeInterval(startTime.tv_usec) / 1_000_000)
            )

            return ProcessSnapshot(
                startDate: startDate,
                debuggerAttached: (info.kp_proc.p_flag & P_TRACED) != 0
            )
        }
    }
}

public enum Yemma4AppConfiguration {
    public static let bundleIdentifier = "com.avmillabs.yemma4"

#if targetEnvironment(simulator)
    public static let supportsLocalModelRuntime = false
#else
    public static let supportsLocalModelRuntime = true
#endif
}

public enum Yemma4DebugOptions {
#if DEBUG
    public static let forceOnboardingOnSimulator =
        ProcessInfo.processInfo.arguments.contains("--yemma-force-onboarding")
        || ProcessInfo.processInfo.environment["YEMMA_FORCE_ONBOARDING"] == "1"
#else
    public static let forceOnboardingOnSimulator = false
#endif
}

@main
public struct Yemma4App: App {
    @UIApplicationDelegateAdaptor(Yemma4AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearancePreference.storageKey) private var appearancePreferenceRaw = AppearancePreference.system.rawValue
    @State private var diagnostics: AppDiagnostics
    @State private var modelDownloader: ModelDownloader
    @State private var llmService: LLMService
    @State private var conversationStore: ConversationStore

    public static let bundleIdentifier = Yemma4AppConfiguration.bundleIdentifier

    public init() {
        let diagnostics = AppDiagnostics.shared
        _diagnostics = State(initialValue: diagnostics)
        var startupMetadata = StartupTiming.launchMetadata()
        startupMetadata["elapsedMs"] = StartupTiming.elapsedMs()
        diagnostics.record(
            "startup: app_init",
            category: "startup",
            metadata: startupMetadata
        )

        let modelDownloader = ModelDownloader()
        _modelDownloader = State(initialValue: modelDownloader)
        diagnostics.record(
            "startup: model_downloader_ready",
            category: "startup",
            metadata: ["elapsedMs": StartupTiming.elapsedMs()]
        )

        let llmService = LLMService()
        _llmService = State(initialValue: llmService)
        diagnostics.record(
            "startup: llm_service_ready",
            category: "startup",
            metadata: ["elapsedMs": StartupTiming.elapsedMs()]
        )

        let conversationStore = ConversationStore()
        _conversationStore = State(initialValue: conversationStore)
        diagnostics.record(
            "startup: conversation_store_ready",
            category: "startup",
            metadata: ["elapsedMs": StartupTiming.elapsedMs()]
        )

        diagnostics.record(
            "startup: services_ready",
            category: "startup",
            metadata: ["elapsedMs": StartupTiming.elapsedMs()]
        )
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(diagnostics)
                .environment(modelDownloader)
                .environment(llmService)
                .environment(conversationStore)
                .preferredColorScheme(AppearancePreference.from(appearancePreferenceRaw).colorScheme)
                .tint(AppTheme.accent)
                .onAppear {
                    AppDiagnostics.shared.record(
                        "startup: root_scene_visible",
                        category: "startup",
                        metadata: ["elapsedMs": StartupTiming.elapsedMs()]
                    )
                    Task {
                        await modelDownloader.appDidBecomeActive()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    AppDiagnostics.shared.record(
                        "startup: scene_phase",
                        category: "startup",
                        metadata: [
                            "phase": String(describing: newPhase),
                            "elapsedMs": StartupTiming.elapsedMs()
                        ]
                    )

                    switch newPhase {
                    case .active:
                        Task {
                            await modelDownloader.appDidBecomeActive()
                        }
                    case .background:
                        modelDownloader.appDidEnterBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
