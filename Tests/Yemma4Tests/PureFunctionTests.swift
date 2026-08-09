import Foundation
import XCTest
@testable import Yemma4

// MARK: - Gemma 4 prompt shaping

final class Gemma4PromptMessageTests: XCTestCase {
    func testPromptMessagesPreserveHistoryAndEveryAttachedImage() {
        let firstImage = PromptImageAsset(id: "first", filePath: "/tmp/first.jpg")
        let secondImage = PromptImageAsset(id: "second", filePath: "/tmp/second.jpg")
        let thirdImage = PromptImageAsset(id: "third", filePath: "/tmp/third.jpg")
        let messages = [
            PromptMessageInput(role: "user", text: "Start here", images: []),
            PromptMessageInput(role: "assistant", text: "Initial context", images: []),
            PromptMessageInput(role: "user", text: "First image", images: [firstImage]),
            PromptMessageInput(role: "assistant", text: "Keep this response", images: []),
            PromptMessageInput(role: "user", text: "Compare these", images: [secondImage, thirdImage]),
        ]

        let shaped = LLMService.promptMessagesForGemma4(from: messages)

        XCTAssertEqual(shaped.map(\.content), messages.map(\.text))
        XCTAssertEqual(shaped.map(\.imageURLs.count), [0, 0, 1, 0, 2])
        XCTAssertEqual(shaped[2].imageURLs.map(\.path), [firstImage.filePath])
        XCTAssertEqual(
            shaped[4].imageURLs.map(\.path),
            [secondImage.filePath, thirdImage.filePath]
        )
    }

    func testPromptMessagesDefaultOnlyImageOnlyUserText() {
        let image = PromptImageAsset(id: "image", filePath: "/tmp/image.jpg")
        let messages = [
            PromptMessageInput(role: "user", text: "  \n", images: [image]),
            PromptMessageInput(role: "assistant", text: "", images: [image]),
            PromptMessageInput(role: "user", text: "", images: []),
        ]

        let shaped = LLMService.promptMessagesForGemma4(from: messages)

        XCTAssertEqual(shaped.count, 2)
        XCTAssertEqual(shaped[0].content, Gemma4MLXSupport.defaultImagePrompt)
        XCTAssertEqual(shaped[1].content, "")
        XCTAssertEqual(shaped.map(\.imageURLs.count), [1, 1])
    }
}

// MARK: - Apple Foundation Model runtime

final class AppleFoundationModelRuntimeTests: XCTestCase {
    func testInitialRuntimeSelectionHonorsPersistenceAndDeviceEligibility() {
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: InferenceRuntime.gemma4.rawValue,
                appleAvailability: .available
            ),
            .gemma4
        )
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: InferenceRuntime.appleFoundationModel.rawValue,
                appleAvailability: .deviceNotEligible
            ),
            .appleFoundationModel
        )
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: nil,
                appleAvailability: .available
            ),
            .appleFoundationModel
        )
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: nil,
                appleAvailability: .requiresIOS26
            ),
            .gemma4
        )
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: nil,
                appleAvailability: .deviceNotEligible
            ),
            .gemma4
        )
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: nil,
                appleAvailability: .modelNotReady
            ),
            .appleFoundationModel
        )
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: nil,
                appleAvailability: .appleIntelligenceNotEnabled
            ),
            .appleFoundationModel
        )
        XCTAssertEqual(
            InferenceRuntime.initialSelection(
                persistedValue: nil,
                appleAvailability: .unsupportedLocale
            ),
            .appleFoundationModel
        )
    }

    func testBoundedHistoryKeepsTheMostRecentContiguousMessages() {
        let history = [
            PromptMessageInput(role: "user", text: "oldest", images: []),
            PromptMessageInput(role: "assistant", text: "boundary", images: []),
            PromptMessageInput(role: "user", text: "five5", images: []),
            PromptMessageInput(role: "assistant", text: "last5", images: []),
        ]

        let bounded = AppleFoundationModelRuntime.boundedHistory(
            history,
            maximumCharacters: 10
        )

        XCTAssertEqual(bounded.map(\.role), ["user", "assistant"])
        XCTAssertEqual(bounded.map(\.text), ["five5", "last5"])
    }

    func testBoundedHistoryDoesNotStartWithAnOrphanedAssistantResponse() {
        let history = [
            PromptMessageInput(role: "user", text: "too long", images: []),
            PromptMessageInput(role: "assistant", text: "ok", images: []),
        ]

        XCTAssertTrue(
            AppleFoundationModelRuntime.boundedHistory(
                history,
                maximumCharacters: 2
            ).isEmpty
        )
    }

    func testSnapshotDeltaConvertsCumulativeSnapshotsAndRejectsReplacement() {
        XCTAssertEqual(
            try AppleFoundationModelRuntime.snapshotDelta(previous: "", current: "Hello"),
            "Hello"
        )
        XCTAssertEqual(
            try AppleFoundationModelRuntime.snapshotDelta(
                previous: "Hello",
                current: "Hello world"
            ),
            " world"
        )
        XCTAssertEqual(
            try AppleFoundationModelRuntime.snapshotDelta(
                previous: "Hello 🌺",
                current: "Hello 🌺!"
            ),
            "!"
        )
        XCTAssertThrowsError(
            try AppleFoundationModelRuntime.snapshotDelta(
                previous: "Hello",
                current: "Retry"
            )
        )
    }

#if targetEnvironment(simulator)
    func testSimulatorGenerationTakesPrecedenceOverSelectedRuntime() async {
        let suiteName = "AppleFoundationModelRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LLMService(defaults: defaults, appleAvailability: .available)
        XCTAssertEqual(service.selectedRuntime, .appleFoundationModel)

        var response = ""
        for await chunk in service.generate(
            prompt: PromptMessageInput(role: "user", text: "Hello", images: []),
            history: []
        ) {
            response += chunk
        }

        XCTAssertTrue(response.contains("Simulator mode reply"))
        XCTAssertTrue(response.contains("Prompt received: Hello"))
        XCTAssertFalse(service.isGenerating)
    }
#endif
}

// MARK: - LLMService response-token math

final class LLMResponseTokenMathTests: XCTestCase {
    private let gigabyte = UInt64(1024) * 1024 * 1024

    func testFocusedPresetUsesSupportedStableTokenLimit() {
        let preset = ResponseStylePreset.focused
        let memory = UInt64(16) * gigabyte

        XCTAssertEqual(preset.maxResponseTokens, 256)
        XCTAssertEqual(
            LLMService.normalizedMaxResponseTokens(
                preset.maxResponseTokens,
                physicalMemory: memory
            ),
            preset.maxResponseTokens
        )
        XCTAssertEqual(
            ResponseStylePreset.matching(
                temperature: preset.temperature,
                maxResponseTokens: preset.maxResponseTokens
            ),
            preset
        )
    }

    func testCeilingBelowSixGigabytesIs1024() {
        let memory = UInt64(4) * gigabyte
        XCTAssertEqual(LLMService.maxResponseTokenCeiling(physicalMemory: memory), 1024)
    }

    func testCeilingJustBelowSixGigabytesIs1024() {
        let memory = UInt64(6) * gigabyte - 1
        XCTAssertEqual(LLMService.maxResponseTokenCeiling(physicalMemory: memory), 1024)
    }

    func testCeilingAtSixGigabytesIs2048() {
        let memory = UInt64(6) * gigabyte
        XCTAssertEqual(LLMService.maxResponseTokenCeiling(physicalMemory: memory), 2048)
    }

    func testCeilingJustBelowEightGigabytesIs2048() {
        let memory = UInt64(8) * gigabyte - 1
        XCTAssertEqual(LLMService.maxResponseTokenCeiling(physicalMemory: memory), 2048)
    }

    func testCeilingAtEightGigabytesIs4096() {
        let memory = UInt64(8) * gigabyte
        XCTAssertEqual(LLMService.maxResponseTokenCeiling(physicalMemory: memory), 4096)
    }

    func testAvailableOptionsFilteredByCeilingFor6GB() {
        let memory = UInt64(6) * gigabyte
        let options = LLMService.availableMaxResponseTokenOptions(physicalMemory: memory)
        XCTAssertEqual(options, [256, 512, 1024, 2048])
    }

    func testAvailableOptionsFilteredByCeilingForLowMemory() {
        let memory = UInt64(4) * gigabyte
        let options = LLMService.availableMaxResponseTokenOptions(physicalMemory: memory)
        XCTAssertEqual(options, [256, 512, 1024])
    }

    func testAvailableOptionsForHighMemoryIncludesAll() {
        let memory = UInt64(16) * gigabyte
        let options = LLMService.availableMaxResponseTokenOptions(physicalMemory: memory)
        XCTAssertEqual(options, LLMService.supportedMaxResponseTokenOptions)
    }

    func testNormalizedKeepsSupportedValue() {
        let memory = UInt64(16) * gigabyte
        XCTAssertEqual(
            LLMService.normalizedMaxResponseTokens(2048, physicalMemory: memory),
            2048
        )
    }

    func testNormalizedClampsAboveCeilingToHighestOption() {
        let memory = UInt64(4) * gigabyte
        // Ceiling is 1024; 4096 is out of range and should clamp down to 1024.
        XCTAssertEqual(
            LLMService.normalizedMaxResponseTokens(4096, physicalMemory: memory),
            1024
        )
    }

    func testNormalizedRoundsDownToNearestSupportedOption() {
        let memory = UInt64(16) * gigabyte
        // 3000 is not a supported option; clamps down to 2048.
        XCTAssertEqual(
            LLMService.normalizedMaxResponseTokens(3000, physicalMemory: memory),
            2048
        )
    }

    func testNormalizedBelowSmallestOptionReturnsSmallestOption() {
        let memory = UInt64(16) * gigabyte
        // 100 is below the smallest supported option (256); returns first option.
        XCTAssertEqual(
            LLMService.normalizedMaxResponseTokens(100, physicalMemory: memory),
            256
        )
    }
}

// MARK: - ModelDownloader ETA formatting

@MainActor
final class FormatETATests: XCTestCase {
    func testSecondsUnderOneMinute() {
        XCTAssertEqual(AppSetupSnapshot.formatETA(0), "less than a minute")
        XCTAssertEqual(AppSetupSnapshot.formatETA(59), "less than a minute")
    }

    func testNegativeSecondsClampToZero() {
        XCTAssertEqual(AppSetupSnapshot.formatETA(-42), "less than a minute")
    }

    func testWholeMinutes() {
        XCTAssertEqual(AppSetupSnapshot.formatETA(60), "1 min")
        XCTAssertEqual(AppSetupSnapshot.formatETA(150), "2 min")
        XCTAssertEqual(AppSetupSnapshot.formatETA(3599), "59 min")
    }

    func testWholeHours() {
        XCTAssertEqual(AppSetupSnapshot.formatETA(3600), "1h")
        XCTAssertEqual(AppSetupSnapshot.formatETA(7200), "2h")
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(AppSetupSnapshot.formatETA(3660), "1h 1m")
        XCTAssertEqual(AppSetupSnapshot.formatETA(3600 + 90 * 60), "2h 30m")
    }
}

// MARK: - Automation configuration parsing

final class Yemma4AutomationConfigurationTests: XCTestCase {
    func testDefaultsAreAllDisabled() {
        let config = Yemma4AutomationConfiguration.from(arguments: [], environment: [:])
        XCTAssertFalse(config.autorunSmokeTest)
        XCTAssertFalse(config.rawTokenLoggingEnabled)
        XCTAssertFalse(config.multimodalFirstTokenTraceEnabled)
    }

    func testAutorunSmokeArgumentVariants() {
        for argument in ["--yemma-autorun-smoke", "--mlx-autorun-smoke"] {
            let config = Yemma4AutomationConfiguration.from(arguments: [argument], environment: [:])
            XCTAssertTrue(config.autorunSmokeTest, "expected \(argument) to enable autorun")
            // Autorun implies the first-token trace.
            XCTAssertTrue(config.multimodalFirstTokenTraceEnabled)
        }
    }

    func testAutorunSmokeEnvironmentVariants() {
        for key in ["YEMMA_AUTORUN_SMOKE", "MLXCHAT_AUTORUN_SMOKE"] {
            let config = Yemma4AutomationConfiguration.from(arguments: [], environment: [key: "1"])
            XCTAssertTrue(config.autorunSmokeTest, "expected \(key)=1 to enable autorun")
        }
    }

    func testAutorunSmokeEnvironmentRequiresExactlyOne() {
        let config = Yemma4AutomationConfiguration.from(
            arguments: [],
            environment: ["YEMMA_AUTORUN_SMOKE": "true"]
        )
        XCTAssertFalse(config.autorunSmokeTest)
    }

    func testRawTokenLoggingFromArgumentAndEnvironment() {
        let fromArgument = Yemma4AutomationConfiguration.from(
            arguments: ["--yemma-log-raw-tokens"],
            environment: [:]
        )
        XCTAssertTrue(fromArgument.rawTokenLoggingEnabled)

        let fromEnvironment = Yemma4AutomationConfiguration.from(
            arguments: [],
            environment: ["YEMMA_LOG_RAW_TOKENS": "1"]
        )
        XCTAssertTrue(fromEnvironment.rawTokenLoggingEnabled)
    }

    func testFirstTokenTraceEnabledIndependentlyOfAutorun() {
        let fromArgument = Yemma4AutomationConfiguration.from(
            arguments: ["--yemma-first-token-trace"],
            environment: [:]
        )
        XCTAssertTrue(fromArgument.multimodalFirstTokenTraceEnabled)
        XCTAssertFalse(fromArgument.autorunSmokeTest)

        let fromEnvironment = Yemma4AutomationConfiguration.from(
            arguments: [],
            environment: ["YEMMA_FIRST_TOKEN_TRACE": "1"]
        )
        XCTAssertTrue(fromEnvironment.multimodalFirstTokenTraceEnabled)
        XCTAssertFalse(fromEnvironment.autorunSmokeTest)
    }
}

// MARK: - Diagnostics persistence ordering

final class DiagnosticsWriterTests: XCTestCase {
    func testOlderSnapshotCannotOverwriteNewerRevision() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let writer = DiagnosticsWriter(defaults: fixture.defaults)
        let olderEvent = DiagnosticEvent(category: "test", message: "older")
        let newerEvent = DiagnosticEvent(category: "test", message: "newer")

        await writer.write(
            events: [olderEvent, newerEvent],
            storageKey: fixture.storageKey,
            revision: 2
        )
        await writer.write(
            events: [olderEvent],
            storageKey: fixture.storageKey,
            revision: 1
        )

        XCTAssertEqual(try fixture.persistedEvents().map(\.message), ["older", "newer"])
    }

    func testClearRejectsWriteFromEarlierRevision() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let writer = DiagnosticsWriter(defaults: fixture.defaults)
        let event = DiagnosticEvent(category: "test", message: "stale")

        await writer.clear(storageKey: fixture.storageKey, revision: 2)
        await writer.write(events: [event], storageKey: fixture.storageKey, revision: 1)

        XCTAssertNil(fixture.defaults.data(forKey: fixture.storageKey))
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "DiagnosticsWriterTests-\(UUID().uuidString)"
        return Fixture(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            suiteName: suiteName,
            storageKey: "events"
        )
    }

    private struct Fixture {
        let defaults: UserDefaults
        let suiteName: String
        let storageKey: String

        func persistedEvents() throws -> [DiagnosticEvent] {
            let data = try XCTUnwrap(defaults.data(forKey: storageKey))
            return try JSONDecoder().decode([DiagnosticEvent].self, from: data)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
