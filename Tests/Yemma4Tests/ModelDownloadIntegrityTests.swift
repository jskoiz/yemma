import CryptoKit
import Foundation
import XCTest
@testable import Yemma4

final class ModelDownloadIntegrityTests: XCTestCase {
    func testGemma4RepositoryRevisionIsPinnedToCommitSHA() {
        let revision = Gemma4MLXSupport.repositoryRevision

        XCTAssertNotEqual(revision, "main")
        XCTAssertEqual(revision.count, 40)
        XCTAssertTrue(revision.allSatisfy(\.isHexDigit))
    }

    func testStrategyUsesSHA256ForBare64HexETag() {
        let etag = String(repeating: "a", count: 64)

        XCTAssertEqual(
            ModelDownloadIntegrity.strategy(forETag: etag),
            .sha256(expected: etag)
        )
    }

    func testStrategyUsesSHA256ForQuotedAndUppercase64HexETag() {
        let digest = "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"

        XCTAssertEqual(
            ModelDownloadIntegrity.strategy(forETag: "\"\(digest)\""),
            .sha256(expected: digest.lowercased())
        )
    }

    func testStrategyFallsBackToSizeForWeakQuotedShortHash() {
        XCTAssertEqual(
            ModelDownloadIntegrity.strategy(forETag: "\"9a0364b9e99bb480\""),
            .size
        )
    }

    func testStrategyFallsBackToSizeForWeakValidatorEvenWhen64Hex() {
        let digest = String(repeating: "b", count: 64)

        XCTAssertEqual(
            ModelDownloadIntegrity.strategy(forETag: "W/\"\(digest)\""),
            .size
        )
    }

    func testStrategyFallsBackToSizeForNonHexETag() {
        // 64 characters but not all hex.
        let nonHex = String(repeating: "z", count: 64)

        XCTAssertEqual(
            ModelDownloadIntegrity.strategy(forETag: nonHex),
            .size
        )
    }

    func testStrategyFallsBackToSizeForEmptyETag() {
        XCTAssertEqual(ModelDownloadIntegrity.strategy(forETag: ""), .size)
    }

    func testStreamedDigestMatchesCryptoKitOverChunkBoundaries() throws {
        let bytes = (0..<(3 * 1024 + 17)).map { UInt8($0 % 251) }
        let payload = Data(bytes)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity-\(UUID().uuidString).bin")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let expected = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()

        // Small chunk size forces multiple read iterations.
        let actual = try ModelDownloadIntegrity.sha256Digest(ofFileAt: fileURL, chunkSize: 512)

        XCTAssertEqual(actual, expected)
    }

    func testStreamedDigestOfEmptyFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity-empty-\(UUID().uuidString).bin")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let expected = SHA256.hash(data: Data())
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(try ModelDownloadIntegrity.sha256Digest(ofFileAt: fileURL), expected)
    }
}
