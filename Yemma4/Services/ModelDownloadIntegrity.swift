import CryptoKit
import Foundation

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
}
