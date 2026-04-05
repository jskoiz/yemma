import Foundation

/// Manages temporary image files for Ask Image sessions.
///
/// Images selected by the user are copied into `Caches/askimage-temp/` so the
/// runtime can read them by path. Files are cleaned up on session reset and
/// stale files (>24h) are pruned on app launch.
enum AskImageTempFiles {

    static let directory: URL = {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("askimage-temp", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches
    }()

    /// Write image data to a temp file and return its path.
    static func store(_ data: Data, fileExtension: String = "jpg") throws -> URL {
        let fileName = UUID().uuidString + "." + fileExtension
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Remove all files in the temp directory.
    static func removeAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for file in files {
            try? fm.removeItem(at: file)
        }

        if !files.isEmpty {
            AppDiagnostics.shared.record(
                "ask_image: temp files cleared",
                category: "ask_image",
                metadata: ["count": files.count]
            )
        }
    }

    /// Remove files older than 24 hours. Call on app launch.
    static func pruneStaleFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var pruned = 0
        for file in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else {
                continue
            }
            try? fm.removeItem(at: file)
            pruned += 1
        }

        if pruned > 0 {
            AppDiagnostics.shared.record(
                "ask_image: pruned stale temp files",
                category: "ask_image",
                metadata: ["pruned": pruned]
            )
        }
    }
}
