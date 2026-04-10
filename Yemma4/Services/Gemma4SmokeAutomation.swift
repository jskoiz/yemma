import Foundation
import Observation
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

struct Yemma4AutomationConfiguration: Sendable, Equatable {
    let autorunSmokeTest: Bool
    let rawTokenLoggingEnabled: Bool
    let multimodalFirstTokenTraceEnabled: Bool

    static let disabled = Self(
        autorunSmokeTest: false,
        rawTokenLoggingEnabled: false,
        multimodalFirstTokenTraceEnabled: false
    )

    static let current = from(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    static func from(arguments: [String], environment: [String: String]) -> Self {
        let argumentSet = Set(arguments)
        let autorunSmokeTest =
            argumentSet.contains("--yemma-autorun-smoke")
            || argumentSet.contains("--mlx-autorun-smoke")
            || environment["YEMMA_AUTORUN_SMOKE"] == "1"
            || environment["MLXCHAT_AUTORUN_SMOKE"] == "1"
        let rawTokenLoggingEnabled =
            argumentSet.contains("--yemma-log-raw-tokens")
            || environment["YEMMA_LOG_RAW_TOKENS"] == "1"
        let multimodalFirstTokenTraceEnabled =
            autorunSmokeTest
            || argumentSet.contains("--yemma-first-token-trace")
            || environment["YEMMA_FIRST_TOKEN_TRACE"] == "1"

        return Self(
            autorunSmokeTest: autorunSmokeTest,
            rawTokenLoggingEnabled: rawTokenLoggingEnabled,
            multimodalFirstTokenTraceEnabled: multimodalFirstTokenTraceEnabled
        )
    }
}

struct Gemma4SmokeReport: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case passed
        case failed
    }

    struct CaseReport: Codable, Sendable, Equatable {
        let name: String
        let prompt: String
        let baseRoles: [String]
        let status: Status
        let response: String
        let errorMessage: String?
        let inferenceSummary: String?
        let promptRouteSummary: String?
        let userInputRouteSummary: String?
        let preparedInputSummary: String?
        let multimodalImageTensorSummary: String?
        let multimodalFirstTokenTraceSummary: String?
        let recentDiagnosticMessages: [String]
    }

    let id: String
    let createdAt: Date
    let status: Status
    let prompt: String
    let imageAssetName: String
    let response: String
    let errorMessage: String?
    let inferenceSummary: String?
    let promptRouteSummary: String?
    let userInputRouteSummary: String?
    let preparedInputSummary: String?
    let multimodalImageTensorSummary: String?
    let multimodalFirstTokenTraceSummary: String?
    let recentDiagnosticMessages: [String]
    let artifactFileName: String
    let cases: [CaseReport]
}

@Observable
@MainActor
final class Gemma4SmokeAutomation {
    private enum SmokeCaseName {
        static let appShaped = "app-shaped"
        static let parity = "parity"
    }

    private enum SmokeCaseKind {
        case appShaped
        case parity
    }

    private struct SmokeCasePlan {
        let name: String
        let prompt: String
        let kind: SmokeCaseKind
        let baseRoles: [String]
    }

    private struct SmokeCaseResult {
        let response: String
        let errorMessage: String?
    }

    private let configuration: Yemma4AutomationConfiguration
    private var hasRunAutomatedSmokeTest = false

    private(set) var latestSmokeReport: Gemma4SmokeReport?

    init(configuration: Yemma4AutomationConfiguration = .current) {
        self.configuration = configuration
    }

    func runIfNeeded(llmService: LLMService) async {
        guard configuration.autorunSmokeTest else {
            return
        }

        guard llmService.isTextModelReady, !llmService.isGenerating, !hasRunAutomatedSmokeTest else {
            return
        }

        hasRunAutomatedSmokeTest = true
        let createdAt = Date()
        var setupError: String?
        var caseReports: [Gemma4SmokeReport.CaseReport] = []

        do {
            let smokeImageURL = try bundledSmokeImageURL()
            for plan in automatedSmokeCasePlans() {
                await llmService.stopGeneration()
                llmService.lastError = nil

                let diagnosticStartIndex = AppDiagnostics.shared.snapshot().count
                AppDiagnostics.shared.record(
                    "Automated smoke test started",
                    category: "smoke",
                    metadata: [
                        "case": plan.name,
                        "prompt": plan.prompt,
                        "imageAsset": Gemma4MLXSupport.automatedSmokeImageAssetName
                    ]
                )

                let result = await runCase(plan, smokeImageURL: smokeImageURL, llmService: llmService)
                let events = Array(AppDiagnostics.shared.snapshot().dropFirst(diagnosticStartIndex))
                caseReports.append(Self.makeCaseReport(plan: plan, result: result, events: events))
            }
        } catch {
            setupError = error.localizedDescription
            AppDiagnostics.shared.record(
                "Automated smoke setup failed",
                category: "smoke",
                metadata: ["error": error.localizedDescription]
            )
        }

        do {
            try persistSmokeReport(
                createdAt: createdAt,
                caseReports: caseReports,
                setupError: setupError
            )
        } catch {
            AppDiagnostics.shared.record(
                "Automated smoke report write failed",
                category: "smoke",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func automatedSmokeCasePlans() -> [SmokeCasePlan] {
        let prompt = Gemma4MLXSupport.defaultImagePrompt
        return [
            SmokeCasePlan(
                name: SmokeCaseName.appShaped,
                prompt: prompt,
                kind: .appShaped,
                baseRoles: []
            ),
            SmokeCasePlan(
                name: SmokeCaseName.parity,
                prompt: prompt,
                kind: .parity,
                baseRoles: []
            ),
        ]
    }

    private func runCase(
        _ plan: SmokeCasePlan,
        smokeImageURL: URL,
        llmService: LLMService
    ) async -> SmokeCaseResult {
        let response: String

        switch plan.kind {
        case .appShaped:
            let attachment = Attachment(
                id: UUID().uuidString,
                url: smokeImageURL,
                type: .image
            )
            let userMessage = ChatMessage(
                id: UUID().uuidString,
                user: .user,
                status: .sent,
                createdAt: Date(),
                text: plan.prompt,
                attachments: [attachment]
            )
            let prompt = YemmaPromptPlanner.promptInput(from: userMessage)
            let history = YemmaPromptPlanner.conversationHistory(from: [])
            response = await collectResponse(
                from: llmService.generate(prompt: prompt, history: history)
            )

        case .parity:
            let prompt = PromptMessageInput(
                role: "user",
                text: plan.prompt,
                images: [
                    PromptImageAsset(
                        id: UUID().uuidString,
                        filePath: smokeImageURL.path
                    )
                ]
            )
            response = await collectResponse(
                from: llmService.generate(prompt: prompt, history: [])
            )
        }

        return SmokeCaseResult(
            response: response,
            errorMessage: llmService.lastError
        )
    }

    private func bundledSmokeImageURL() throws -> URL {
#if canImport(UIKit)
        guard let image = UIImage(named: Gemma4MLXSupport.automatedSmokeImageAssetName),
            let imageData = image.jpegData(compressionQuality: 0.9)
        else {
            throw CocoaError(
                .fileReadNoSuchFile,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Bundled smoke image '\(Gemma4MLXSupport.automatedSmokeImageAssetName)' is missing."
                ]
            )
        }

        return try persistSmokeImage(imageData)
#else
        throw CocoaError(.featureUnsupported)
#endif
    }

    private func persistSmokeImage(_ imageData: Data) throws -> URL {
        let directory = ConversationAttachmentStore.directoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileURL = directory.appendingPathComponent("gemma4-smoke-image.jpg")
        try imageData.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private func collectResponse(from stream: AsyncStream<String>) async -> String {
        var policy = StreamingUpdatePolicy()

        for await token in stream {
            _ = policy.append(token)
        }

        return policy.finalize()
    }

    private static func makeCaseReport(
        plan: SmokeCasePlan,
        result: SmokeCaseResult,
        events: [DiagnosticEvent]
    ) -> Gemma4SmokeReport.CaseReport {
        let responseText = result.response.trimmingCharacters(in: .whitespacesAndNewlines)
        let status: Gemma4SmokeReport.Status =
            responseText.isEmpty || result.errorMessage != nil ? .failed : .passed

        return Gemma4SmokeReport.CaseReport(
            name: plan.name,
            prompt: plan.prompt,
            baseRoles: plan.baseRoles,
            status: status,
            response: result.response,
            errorMessage: result.errorMessage,
            inferenceSummary: inferenceSummary(from: events),
            promptRouteSummary: promptRouteSummary(from: events),
            userInputRouteSummary: userInputRouteSummary(from: events),
            preparedInputSummary: preparedInputSummary(from: events),
            multimodalImageTensorSummary: summaryValue(
                for: "Multimodal image tensor",
                in: events
            ),
            multimodalFirstTokenTraceSummary: summaryValue(
                for: "Multimodal first-token trace",
                in: events
            ),
            recentDiagnosticMessages: Array(events.suffix(40)).map(formatDiagnosticEvent)
        )
    }

    private func persistSmokeReport(
        createdAt: Date,
        caseReports: [Gemma4SmokeReport.CaseReport],
        setupError: String?
    ) throws {
        let artifactFileName = "\(Self.smokeReportID(for: createdAt)).json"
        let primaryCase = caseReports.first(where: { $0.name == SmokeCaseName.appShaped })
            ?? caseReports.first
        let status: Gemma4SmokeReport.Status =
            setupError == nil && caseReports.allSatisfy { $0.status == .passed } ? .passed : .failed
        let report = Gemma4SmokeReport(
            id: Self.smokeReportID(for: createdAt),
            createdAt: createdAt,
            status: status,
            prompt: primaryCase?.prompt ?? Gemma4MLXSupport.defaultImagePrompt,
            imageAssetName: Gemma4MLXSupport.automatedSmokeImageAssetName,
            response: primaryCase?.response ?? "",
            errorMessage: setupError ?? primaryCase?.errorMessage,
            inferenceSummary: primaryCase?.inferenceSummary,
            promptRouteSummary: primaryCase?.promptRouteSummary,
            userInputRouteSummary: primaryCase?.userInputRouteSummary,
            preparedInputSummary: primaryCase?.preparedInputSummary,
            multimodalImageTensorSummary: primaryCase?.multimodalImageTensorSummary,
            multimodalFirstTokenTraceSummary: primaryCase?.multimodalFirstTokenTraceSummary,
            recentDiagnosticMessages: Array(AppDiagnostics.shared.snapshot().suffix(24)).map(
                Self.formatDiagnosticEvent
            ),
            artifactFileName: artifactFileName,
            cases: caseReports
        )

        let artifactURL = try smokeReportsDirectory().appending(path: artifactFileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: artifactURL, options: [.atomic])
        latestSmokeReport = report

        AppDiagnostics.shared.record(
            "Automated smoke report saved",
            category: "smoke",
            metadata: [
                "id": report.id,
                "status": report.status.rawValue,
                "file": artifactURL.lastPathComponent
            ]
        )
    }

    private func smokeReportsDirectory() throws -> URL {
        let cachesDirectory =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = cachesDirectory
            .appending(path: "Yemma4", directoryHint: .isDirectory)
            .appending(path: "SmokeReports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func smokeReportID(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "gemma4-smoke-\(formatter.string(from: date))"
    }

    private static func promptRouteSummary(from events: [DiagnosticEvent]) -> String? {
        guard let event = events.last(where: { $0.message == "Prompt route" }) else {
            return nil
        }

        return "route=\(event.metadata["route"] ?? "unknown") promptMessages=\(event.metadata["promptMessages"] ?? "?") imageAttachments=\(event.metadata["imageAttachments"] ?? "?")"
    }

    private static func userInputRouteSummary(from events: [DiagnosticEvent]) -> String? {
        guard let event = events.last(where: { $0.message == "UserInput route" }) else {
            return nil
        }

        return
            "route=\(event.metadata["route"] ?? "unknown") internalChat=roles=\(event.metadata["roles"] ?? "[]") latestUser=\"\(event.metadata["latestUser"] ?? "")\" messageCount=\(event.metadata["messageCount"] ?? "?") images=\(event.metadata["images"] ?? "?") videos=\(event.metadata["videos"] ?? "?")"
    }

    private static func preparedInputSummary(from events: [DiagnosticEvent]) -> String? {
        guard let event = events.last(where: { $0.message == "Prepared input" }) else {
            return nil
        }

        return "tokens=\(event.metadata["tokens"] ?? "?") image=\(event.metadata["image"] ?? "?")"
    }

    private static func inferenceSummary(from events: [DiagnosticEvent]) -> String? {
        guard let event = events.last(where: { $0.message == "Generation finished" }) else {
            return nil
        }

        guard
            let promptTokens = event.metadata["promptTokens"],
            let generationTokens = event.metadata["generationTokens"],
            let tokensPerSecond = event.metadata["tokensPerSecond"]
        else {
            return nil
        }

        return "Prompt \(promptTokens) tok • Gen \(generationTokens) tok • \(tokensPerSecond) tok/s"
    }

    private static func summaryValue(for message: String, in events: [DiagnosticEvent]) -> String? {
        events.last(where: { $0.message == message })?.metadata["summary"]
    }

    private static func formatDiagnosticEvent(_ event: DiagnosticEvent) -> String {
        guard !event.metadata.isEmpty else {
            return event.message
        }

        let pairs = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "\(event.message) [\(pairs)]"
    }
}
