import Foundation
import XCTest
@testable import Yemma4

// MARK: - Gemma4ModelSource parsing/validation

final class Gemma4ModelSourceTests: XCTestCase {
    func testFromUserInputAcceptsOwnerRepositoryID() throws {
        let source = try Gemma4ModelSource.fromUserInput("mlx-community/gemma-4-e2b-it-4bit")

        XCTAssertEqual(source.repositoryID, "mlx-community/gemma-4-e2b-it-4bit")
        // This repository id matches the default preset, so it resolves to a preset source.
        XCTAssertEqual(source.kind, .preset)
        XCTAssertEqual(source.preset, .defaultE2B)
    }

    func testFromUserInputAcceptsCustomRepositoryID() throws {
        let source = try Gemma4ModelSource.fromUserInput("someowner/some-repo")

        XCTAssertEqual(source.repositoryID, "someowner/some-repo")
        XCTAssertEqual(source.kind, .custom)
        XCTAssertNil(source.preset)
        XCTAssertTrue(source.isCustom)
        XCTAssertEqual(source.sourceURLString, "https://huggingface.co/someowner/some-repo")
    }

    func testFromUserInputTrimsSurroundingWhitespace() throws {
        let source = try Gemma4ModelSource.fromUserInput("   someowner/some-repo  \n")

        XCTAssertEqual(source.repositoryID, "someowner/some-repo")
    }

    func testFromUserInputAcceptsFullHuggingFaceURL() throws {
        let source = try Gemma4ModelSource.fromUserInput("https://huggingface.co/someowner/some-repo")

        XCTAssertEqual(source.repositoryID, "someowner/some-repo")
    }

    func testFromUserInputAcceptsWWWHostAndExtraPathComponents() throws {
        let source = try Gemma4ModelSource.fromUserInput(
            "https://www.huggingface.co/someowner/some-repo/tree/main"
        )

        XCTAssertEqual(source.repositoryID, "someowner/some-repo")
    }

    func testParseRepositoryIDReturnsNormalizedOwnerRepo() throws {
        let parsed = try Gemma4ModelSource.parseRepositoryID(from: "someowner/some-repo")
        XCTAssertEqual(parsed, "someowner/some-repo")
    }

    func testParseRepositoryIDFromURLReturnsFirstTwoPathComponents() throws {
        let parsed = try Gemma4ModelSource.parseRepositoryID(
            from: "https://huggingface.co/someowner/some-repo/blob/main/config.json"
        )
        XCTAssertEqual(parsed, "someowner/some-repo")
    }

    func testEmptyInputThrowsEmptyInput() {
        assertThrows(.emptyInput) {
            try Gemma4ModelSource.fromUserInput("   \n  ")
        }
    }

    func testUnsupportedHostThrowsUnsupportedHost() {
        assertThrows(.unsupportedHost("https://example.com/owner/repo")) {
            try Gemma4ModelSource.fromUserInput("https://example.com/owner/repo")
        }
    }

    func testNonHTTPSchemeWithUnsupportedHostThrowsUnsupportedHost() {
        assertThrows(.unsupportedHost("ftp://huggingface.co.evil.com/owner/repo")) {
            try Gemma4ModelSource.fromUserInput("ftp://huggingface.co.evil.com/owner/repo")
        }
    }

    func testHuggingFaceURLWithoutRepositoryThrowsMissingRepository() {
        assertThrows(.missingRepository("https://huggingface.co/owner")) {
            try Gemma4ModelSource.fromUserInput("https://huggingface.co/owner")
        }
    }

    func testInvalidRepositoryIDWithoutSlashThrowsInvalidRepositoryID() {
        assertThrows(.invalidRepositoryID("justaname")) {
            try Gemma4ModelSource.fromUserInput("justaname")
        }
    }

    func testInvalidRepositoryIDWithTooManyComponentsThrowsInvalidRepositoryID() {
        assertThrows(.invalidRepositoryID("a/b/c")) {
            try Gemma4ModelSource.fromUserInput("a/b/c")
        }
    }

    func testNormalizeRepositoryIDRejectsInternalWhitespace() {
        assertThrows(.invalidRepositoryID("owner/some repo")) {
            _ = try Gemma4ModelSource.normalizeRepositoryID("owner/some repo")
        }
    }

    func testNormalizeRepositoryIDCollapsesEmptyPathSegments() throws {
        // split(omittingEmptySubsequences: true) drops the empty segment from the
        // doubled slash, yielding exactly two components.
        let normalized = try Gemma4ModelSource.normalizeRepositoryID("owner//repo")
        XCTAssertEqual(normalized, "owner/repo")
    }

    private func assertThrows(
        _ expected: Gemma4ModelSourceInputError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let typed = error as? Gemma4ModelSourceInputError else {
                XCTFail("Expected Gemma4ModelSourceInputError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(typed, expected, file: file, line: line)
        }
    }
}

// MARK: - LLMService response-token math

final class LLMResponseTokenMathTests: XCTestCase {
    private let gigabyte = UInt64(1024) * 1024 * 1024

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
