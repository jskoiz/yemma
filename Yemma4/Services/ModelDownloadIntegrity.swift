import CryptoKit
import Foundation

struct ModelDownloadVerificationReceipt: Codable, Equatable, Sendable {
    let revision: String
    let expectedBytes: Int64
    let etag: String
    let sha256: String?
    let modificationDate: Date?

    func updatingModificationDate(from fileURL: URL) -> ModelDownloadVerificationReceipt {
        ModelDownloadVerificationReceipt(
            revision: revision,
            expectedBytes: expectedBytes,
            etag: etag,
            sha256: sha256,
            modificationDate: Self.modificationDate(for: fileURL)
        )
    }

    private static func modificationDate(for fileURL: URL) -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

enum ModelDownloadIntegrityError: LocalizedError, Equatable {
    case unreadableFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case digestMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The downloaded file could not be read."
        case let .sizeMismatch(expected, actual):
            return "Downloaded file size did not match. Expected \(expected) bytes, found \(actual)."
        case let .digestMismatch(expected, actual):
            return "Downloaded file SHA-256 did not match. Expected \(expected), found \(actual)."
        }
    }
}

/// Pure helpers for verifying the integrity of downloaded model files.
///
/// Hugging Face exposes per-file `etag` values. For LFS-backed files (the large
/// `.safetensors` shards) the etag is the file's SHA-256 digest, which lets us
/// detect a correctly-sized-but-corrupt download. For small, non-LFS files the
/// etag is a weak hash (often an MD5 or a quoted short hash) that we cannot use
/// as a content checksum, so we fall back to the byte-size check.
enum ModelDownloadIntegrity {
    /// How a downloaded file should be verified.
    enum VerificationStrategy: Equatable {
        /// The etag is an LFS SHA-256 digest; verify the file's streamed digest
        /// against `expectedSHA256` (lowercase, 64 hex characters).
        case sha256(expected: String)
        /// The etag is weak/non-sha; fall back to the existing byte-size check.
        case size
    }

    /// Decides how to verify a file given the metadata etag captured in the
    /// download manifest. Pure and side-effect free for unit testing.
    static func strategy(forETag etag: String) -> VerificationStrategy {
        guard let normalized = normalizedSHA256(fromETag: etag) else {
            return .size
        }
        return .sha256(expected: normalized)
    }

    /// Extracts a normalized (lowercase, 64-hex) SHA-256 digest from a raw etag
    /// if and only if the etag is a strong SHA-256 hash. Returns `nil` for weak
    /// etags (wrong length, non-hex, or weak-validator `W/"..."` markers).
    static func normalizedSHA256(fromETag etag: String) -> String? {
        var value = etag.trimmingCharacters(in: .whitespacesAndNewlines)

        // Weak validators ("W/\"...\"") are never content checksums.
        if value.hasPrefix("W/") || value.hasPrefix("w/") {
            return nil
        }

        // Strip surrounding quotes that HTTP etags are frequently wrapped in.
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard value.count == 64 else {
            return nil
        }

        let lowercased = value.lowercased()
        guard lowercased.allSatisfy(\.isHexDigit) else {
            return nil
        }

        return lowercased
    }

    /// Streams the file at `fileURL` through SHA-256 in bounded-size chunks so
    /// multi-gigabyte shards never load fully into memory.
    static func sha256Digest(
        ofFileAt fileURL: URL,
        chunkSize: Int = 1 << 20
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Verifies a file and returns the provenance needed to decide whether a
    /// later cached copy still belongs to the same model revision.
    static func verify(
        fileAt fileURL: URL,
        expectedBytes: Int64,
        etag: String,
        revision: String = ""
    ) throws -> ModelDownloadVerificationReceipt {
        let resourceValues = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        )
        guard resourceValues.isRegularFile == true else {
            throw ModelDownloadIntegrityError.unreadableFile
        }

        let actualBytes = Int64(resourceValues.fileSize ?? 0)
        guard actualBytes == expectedBytes else {
            throw ModelDownloadIntegrityError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }

        switch strategy(forETag: etag) {
        case let .sha256(expected):
            let actual = try sha256Digest(ofFileAt: fileURL)
            guard actual == expected else {
                throw ModelDownloadIntegrityError.digestMismatch(expected: expected, actual: actual)
            }
            return ModelDownloadVerificationReceipt(
                revision: revision,
                expectedBytes: expectedBytes,
                etag: etag,
                sha256: actual,
                modificationDate: resourceValues.contentModificationDate
            )
        case .size:
            return ModelDownloadVerificationReceipt(
                revision: revision,
                expectedBytes: expectedBytes,
                etag: etag,
                sha256: nil,
                modificationDate: resourceValues.contentModificationDate
            )
        }
    }

    /// A receipt is only reusable when the revision and manifest metadata are
    /// unchanged and the file's size and modification date still match the
    /// file that was verified.
    static func receiptMatches(
        _ receipt: ModelDownloadVerificationReceipt,
        fileAt fileURL: URL,
        revision: String,
        expectedBytes: Int64,
        etag: String
    ) -> Bool {
        guard receipt.revision == revision,
              receipt.expectedBytes == expectedBytes,
              receipt.etag == etag,
              let values = try? fileURL.resourceValues(
                  forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
              ),
              values.isRegularFile == true,
              Int64(values.fileSize ?? 0) == expectedBytes else {
            return false
        }

        return receipt.modificationDate == values.contentModificationDate
    }

    /// Resume data that fails without producing replacement data must not be
    /// retried forever. Cancellation is user-initiated and should remain a
    /// cancellation rather than starting a fresh task behind the user's back.
    static func shouldDiscardResumeData(after error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return false
        }
        return true
    }
}
