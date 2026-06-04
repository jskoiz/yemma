import Foundation
import XCTest
@testable import Yemma4

final class ModelDownloadStorageCheckTests: XCTestCase {
    private let gigabyte: Int64 = 1_073_741_824

    func testRequiredBytesUsesFlatHeadroomForSmallModels() {
        // 100 MB model: 10% headroom (10 MB) is below the 500 MB floor, so the
        // flat headroom should win.
        let modelBytes: Int64 = 100 * 1024 * 1024
        let expected = modelBytes + ModelDownloadStorageCheck.minimumHeadroomBytes
        XCTAssertEqual(
            ModelDownloadStorageCheck.requiredBytes(forModelBytes: modelBytes),
            expected
        )
    }

    func testRequiredBytesUsesProportionalHeadroomForLargeModels() {
        // ~4.2 GB model: 10% (~430 MB) is below 500 MB, so flat headroom still wins.
        let modelBytes: Int64 = Int64(4.2 * Double(gigabyte))
        let expected = modelBytes + ModelDownloadStorageCheck.minimumHeadroomBytes
        XCTAssertEqual(
            ModelDownloadStorageCheck.requiredBytes(forModelBytes: modelBytes),
            expected
        )

        // 10 GB model: 10% (1 GB) exceeds the flat floor and should win.
        let bigModel: Int64 = 10 * gigabyte
        let bigExpected = bigModel + Int64(Double(bigModel) * 0.1)
        XCTAssertEqual(
            ModelDownloadStorageCheck.requiredBytes(forModelBytes: bigModel),
            bigExpected
        )
    }

    func testHasSufficientCapacityWhenRoomIsAvailable() {
        let modelBytes: Int64 = Int64(4.2 * Double(gigabyte))
        let available = ModelDownloadStorageCheck.requiredBytes(forModelBytes: modelBytes)
        XCTAssertTrue(
            ModelDownloadStorageCheck.hasSufficientCapacity(
                modelBytes: modelBytes,
                availableBytes: available
            )
        )
    }

    func testInsufficientCapacityWhenJustBelowThreshold() {
        let modelBytes: Int64 = Int64(4.2 * Double(gigabyte))
        let available = ModelDownloadStorageCheck.requiredBytes(forModelBytes: modelBytes) - 1
        XCTAssertFalse(
            ModelDownloadStorageCheck.hasSufficientCapacity(
                modelBytes: modelBytes,
                availableBytes: available
            )
        )
    }

    func testInsufficientStorageMessageMentionsGigabytesNeeded() {
        let modelBytes: Int64 = Int64(4.2 * Double(gigabyte))
        let message = ModelDownloadStorageCheck.insufficientStorageMessage(forModelBytes: modelBytes)
        XCTAssertTrue(message.contains("Not enough storage"))
        XCTAssertTrue(message.contains("GB"))
    }

    func testFormattedGigabytesRoundsUp() {
        // 4.7 GB exactly -> "4.7 GB"
        let bytes = Int64(4.7 * Double(gigabyte))
        XCTAssertEqual(ModelDownloadStorageCheck.formattedGigabytes(bytes), "4.7 GB")
    }

    func testNegativeInputsAreClamped() {
        XCTAssertEqual(
            ModelDownloadStorageCheck.requiredBytes(forModelBytes: -100),
            ModelDownloadStorageCheck.minimumHeadroomBytes
        )
        XCTAssertEqual(ModelDownloadStorageCheck.formattedGigabytes(-5), "0.0 GB")
    }
}
