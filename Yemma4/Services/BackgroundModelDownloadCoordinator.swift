import Foundation
@preconcurrency import Hub

enum ModelDownloadStorageCheck {
    /// Headroom added on top of the model size so the download has room for
    /// temporary files and leaves the device usable. Whichever is larger of a
    /// flat 500 MB or 10% of the model size.
    static let minimumHeadroomBytes: Int64 = 500 * 1024 * 1024

    static func requiredBytes(forModelBytes modelBytes: Int64) -> Int64 {
        let modelBytes = max(modelBytes, 0)
        let proportionalHeadroom = Int64(Double(modelBytes) * 0.1)
        return modelBytes + max(minimumHeadroomBytes, proportionalHeadroom)
    }

    static func hasSufficientCapacity(modelBytes: Int64, availableBytes: Int64) -> Bool {
        availableBytes >= requiredBytes(forModelBytes: modelBytes)
    }

    static func insufficientStorageMessage(forModelBytes modelBytes: Int64) -> String {
        let neededGB = formattedGigabytes(requiredBytes(forModelBytes: modelBytes))
        return "Not enough storage — Yemma needs about \(neededGB) free to download the model. Free up some space and try again."
    }

    static func formattedGigabytes(_ bytes: Int64) -> String {
        let gigabytes = Double(max(bytes, 0)) / 1_073_741_824
        let rounded = (gigabytes * 10).rounded(.up) / 10
        return String(format: "%.1f GB", rounded)
    }
}

struct InsufficientStorageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BackgroundModelDownloadSnapshot: Sendable {
    let totalBytes: Int64
    let completedBytes: Int64
    let hasRunningTasks: Bool
    let hasPendingWork: Bool
    let lastError: String?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }
}

final class BackgroundModelDownloadCoordinator: NSObject, @unchecked Sendable {
    static let shared = BackgroundModelDownloadCoordinator()
    static let sessionIdentifier = "\(Yemma4AppConfiguration.bundleIdentifier).model-download"
    private static let stateFileName = "download-state.json"
    private static let backgroundCacheDirectoryName = "yemma-background-download"

    private struct PersistedState: Codable, Sendable {
        let manifest: DownloadManifest
        var lastError: String?
    }

    private struct DownloadManifest: Codable, Sendable {
        let repositoryID: String
        let revision: String
        let files: [DownloadFile]

        var totalBytes: Int64 {
            files.reduce(into: Int64(0)) { partialResult, file in
                partialResult += file.expectedBytes
            }
        }
    }

    private struct DownloadFile: Codable, Sendable {
        let relativePath: String
        let sourceURL: String
        let expectedBytes: Int64
        let etag: String
        let commitHash: String
    }

    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let completionHandlerLock = NSLock()
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        super.init()
    }

    func registerBackgroundCompletionHandler(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }

        completionHandlerLock.lock()
        backgroundCompletionHandler = completionHandler
        completionHandlerLock.unlock()

        _ = session
    }

    func startDownload(
        using hub: HubApi,
        repositoryID: String,
        revision: String,
        matching patterns: [String]
    ) async throws -> BackgroundModelDownloadSnapshot {
        _ = session

        let manifest = try await persistedOrFreshManifest(
            using: hub,
            repositoryID: repositoryID,
            revision: revision,
            matching: patterns
        )

        try ensureSufficientStorage(for: manifest, hub: hub)

        try await enqueueMissingTasks(using: manifest, hub: hub)
        return await snapshot(using: hub, repositoryID: repositoryID)
    }

    private func ensureSufficientStorage(
        for manifest: DownloadManifest,
        hub: HubApi
    ) throws {
        // Only the not-yet-downloaded files will consume new space.
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: manifest.repositoryID))
        let remainingBytes = manifest.files.reduce(into: Int64(0)) { partialResult, file in
            guard !completedFileExists(file, in: repoLocation) else {
                return
            }
            partialResult += file.expectedBytes
        }

        guard remainingBytes > 0 else {
            return
        }

        guard let availableBytes = availableCapacityBytes(forVolumeContaining: repoLocation) else {
            // If the capacity can't be determined, don't block the download.
            return
        }

        guard
            ModelDownloadStorageCheck.hasSufficientCapacity(
                modelBytes: remainingBytes,
                availableBytes: availableBytes
            )
        else {
            let message = ModelDownloadStorageCheck.insufficientStorageMessage(forModelBytes: remainingBytes)
            AppDiagnostics.shared.record(
                "Blocked MLX model download: insufficient storage",
                category: "download",
                metadata: [
                    "repository": manifest.repositoryID,
                    "requiredBytes": String(ModelDownloadStorageCheck.requiredBytes(forModelBytes: remainingBytes)),
                    "availableBytes": String(availableBytes)
                ]
            )
            throw InsufficientStorageError(message: message)
        }
    }

    private func availableCapacityBytes(forVolumeContaining url: URL) -> Int64? {
        // Resolve to an existing directory on the destination volume so the
        // volume resource lookup succeeds even before the repo folder exists.
        var probeURL = url
        while !fileManager.fileExists(atPath: probeURL.path) {
            let parent = probeURL.deletingLastPathComponent()
            guard parent.path != probeURL.path else {
                break
            }
            probeURL = parent
        }

        guard
            let values = try? probeURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }

        return capacity
    }

    func snapshot(using hub: HubApi, repositoryID: String) async -> BackgroundModelDownloadSnapshot {
        guard let persistedState = loadState(using: hub, repositoryID: repositoryID) else {
            return BackgroundModelDownloadSnapshot(
                totalBytes: 0,
                completedBytes: 0,
                hasRunningTasks: false,
                hasPendingWork: false,
                lastError: nil
            )
        }

        let manifest = persistedState.manifest
        let tasks = await currentTasks()
        let scopedTasks = tasks.filter { task in
            guard let descriptor = Self.parseTaskDescription(task.taskDescription) else {
                return false
            }
            return descriptor.repositoryID == repositoryID
        }
        let runningTasks = scopedTasks.filter { $0.state == .running || $0.state == .suspended }
        let taskMap: [String: URLSessionTask] = tasks.reduce(into: [:]) { partialResult, task in
            guard let descriptor = Self.parseTaskDescription(task.taskDescription) else {
                return
            }
            guard descriptor.repositoryID == repositoryID else {
                return
            }
            partialResult[descriptor.relativePath] = task
        }

        let repoLocation = hub.localRepoLocation(Hub.Repo(id: manifest.repositoryID))
        var completedBytes: Int64 = 0
        var hasPendingWork = false

        for file in manifest.files {
            if completedFileExists(file, in: repoLocation) {
                completedBytes += file.expectedBytes
                continue
            }

            if let task = taskMap[file.relativePath] {
                hasPendingWork = true
                completedBytes += max(Int64(task.countOfBytesReceived), 0)
                continue
            }

            if resumeDataExists(for: file, in: repoLocation) {
                hasPendingWork = true
                continue
            }
        }

        let isComplete = manifest.files.allSatisfy { completedFileExists($0, in: repoLocation) }
        if isComplete {
            return BackgroundModelDownloadSnapshot(
                totalBytes: manifest.totalBytes,
                completedBytes: manifest.totalBytes,
                hasRunningTasks: !runningTasks.isEmpty,
                hasPendingWork: false,
                lastError: nil
            )
        }

        return BackgroundModelDownloadSnapshot(
            totalBytes: manifest.totalBytes,
            completedBytes: min(completedBytes, manifest.totalBytes),
            hasRunningTasks: !runningTasks.isEmpty,
            hasPendingWork: hasPendingWork,
            lastError: persistedState.lastError
        )
    }

    func clearState(using hub: HubApi, repositoryID: String) async {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: repositoryID))
        try? await cancelTasks(repositoryID: repositoryID)
        try? fileManager.removeItem(at: cacheDirectory(for: repoLocation))
    }

    private func persistedOrFreshManifest(
        using hub: HubApi,
        repositoryID: String,
        revision: String,
        matching patterns: [String]
    ) async throws -> DownloadManifest {
        let repo = Hub.Repo(id: repositoryID)
        let repoLocation = hub.localRepoLocation(repo)

        if let persistedState = loadState(using: hub, repositoryID: repositoryID),
            persistedState.manifest.repositoryID == repositoryID,
            persistedState.manifest.revision == revision
        {
            return persistedState.manifest
        }

        try? await cancelTasks(repositoryID: repositoryID)
        try? fileManager.removeItem(at: cacheDirectory(for: repoLocation))

        let manifest = try await buildManifest(
            using: hub,
            repositoryID: repositoryID,
            revision: revision,
            matching: patterns
        )
        saveState(PersistedState(manifest: manifest, lastError: nil), using: hub)
        return manifest
    }

    private func buildManifest(
        using hub: HubApi,
        repositoryID: String,
        revision: String,
        matching patterns: [String]
    ) async throws -> DownloadManifest {
        let repo = Hub.Repo(id: repositoryID)
        let filenames = try await hub.getFilenames(from: repo, revision: revision, matching: patterns).sorted()
        let endpoint = URL(string: "https://huggingface.co")!
        var files: [DownloadFile] = []

        for relativePath in filenames {
            let sourceURL = endpoint
                .appending(path: repositoryID)
                .appending(path: "resolve")
                .appending(component: revision)
                .appending(path: relativePath)
            let metadata = try await hub.getFileMetadata(url: sourceURL)

            guard
                let size = metadata.size,
                let etag = metadata.etag,
                let commitHash = metadata.commitHash
            else {
                throw Hub.HubClientError.downloadError(
                    "Missing metadata for \(relativePath)."
                )
            }

            files.append(
                DownloadFile(
                    relativePath: relativePath,
                    sourceURL: sourceURL.absoluteString,
                    expectedBytes: Int64(size),
                    etag: etag,
                    commitHash: commitHash
                )
            )
        }

        // All files must resolve to a single commit hash. If the upstream
        // repository changes while a floating revision (e.g. "main") is being
        // resolved, the per-file commit hashes diverge and we refuse to build an
        // inconsistent manifest rather than mixing snapshots.
        let commitHashes = Set(files.map(\.commitHash))
        if commitHashes.count > 1 {
            throw Hub.HubClientError.downloadError(
                "Model files resolved to inconsistent commit hashes for \(repositoryID); "
                    + "the upstream revision changed mid-resolution."
            )
        }

        return DownloadManifest(
            repositoryID: repositoryID,
            revision: revision,
            files: files
        )
    }

    private func enqueueMissingTasks(
        using manifest: DownloadManifest,
        hub: HubApi
    ) async throws {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: manifest.repositoryID))
        let existingTasks = await currentTasks()
        let existingTaskDescriptions = Set(existingTasks.compactMap(\.taskDescription))

        for file in manifest.files {
            if completedFileExists(file, in: repoLocation) {
                continue
            }

            if existingTaskDescriptions.contains(
                Self.taskDescription(repositoryID: manifest.repositoryID, relativePath: file.relativePath)
            ) {
                continue
            }

            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeDataURL(for: file, in: repoLocation)) {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                guard let url = URL(string: file.sourceURL) else {
                    // A file we cannot turn into a task would silently never download,
                    // leaving the bundle incomplete with no pending work. Surface it.
                    updateLastError(
                        "Invalid download URL for \(file.relativePath).",
                        repositoryID: manifest.repositoryID
                    )
                    AppDiagnostics.shared.record(
                        "Skipped background model download with invalid source URL",
                        category: "download",
                        metadata: [
                            "file": file.relativePath,
                            "sourceURL": file.sourceURL
                        ]
                    )
                    continue
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                task = session.downloadTask(with: request)
            }

            task.taskDescription = Self.taskDescription(
                repositoryID: manifest.repositoryID,
                relativePath: file.relativePath
            )
            task.resume()
        }
    }

    /// Verifies a freshly-downloaded file at `destination` against the manifest
    /// entry. When the captured etag is an LFS SHA-256 the file's streamed digest
    /// must match; otherwise the existing byte-size check is used. Throws on any
    /// mismatch so the caller can discard the file.
    private func verifyDownloadedFile(_ file: DownloadFile, at destination: URL) throws {
        switch ModelDownloadIntegrity.strategy(forETag: file.etag) {
        case let .sha256(expected):
            let actual = try ModelDownloadIntegrity.sha256Digest(ofFileAt: destination)
            guard actual == expected else {
                throw Hub.HubClientError.downloadError(
                    "Downloaded file SHA-256 did not match \(file.relativePath)."
                )
            }
        case .size:
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
                let fileSize = attributes[.size] as? NSNumber,
                fileSize.int64Value == file.expectedBytes
            else {
                throw Hub.HubClientError.downloadError(
                    "Downloaded file size did not match \(file.relativePath)."
                )
            }
        }
    }

    private func completedFileExists(_ file: DownloadFile, in repoLocation: URL) -> Bool {
        let destination = repoLocation.appending(path: file.relativePath)
        guard fileManager.fileExists(atPath: destination.path) else {
            return false
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return false
        }

        return fileSize.int64Value == file.expectedBytes
    }

    private func loadState(using hub: HubApi, repositoryID: String) -> PersistedState? {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: repositoryID))
        let stateURL = stateURL(for: repoLocation)
        guard let data = try? Data(contentsOf: stateURL) else {
            return nil
        }

        return try? decoder.decode(PersistedState.self, from: data)
    }

    private func saveState(_ state: PersistedState, using hub: HubApi) {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: state.manifest.repositoryID))
        let stateURL = stateURL(for: repoLocation)

        do {
            try fileManager.createDirectory(
                at: cacheDirectory(for: repoLocation),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            AppDiagnostics.shared.record(
                "Failed to persist background model download state",
                category: "download",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func updateLastError(_ message: String?, repositoryID: String) {
        let hub = HubApi.shared
        guard var state = loadState(using: hub, repositoryID: repositoryID) else {
            return
        }
        state.lastError = message
        saveState(state, using: hub)
    }

    private static func taskDescription(repositoryID: String, relativePath: String) -> String {
        "\(repositoryID)|\(relativePath)"
    }

    private static func parseTaskDescription(_ rawValue: String?) -> (repositoryID: String, relativePath: String)? {
        guard let rawValue, let separatorIndex = rawValue.firstIndex(of: "|") else {
            return nil
        }

        let repositoryID = String(rawValue[..<separatorIndex])
        let relativePath = String(rawValue[rawValue.index(after: separatorIndex)...])
        guard !repositoryID.isEmpty, !relativePath.isEmpty else {
            return nil
        }

        return (repositoryID, relativePath)
    }

    private func cacheDirectory(for repoLocation: URL) -> URL {
        repoLocation
            .appending(path: ".cache")
            .appending(path: Self.backgroundCacheDirectoryName)
    }

    private func stateURL(for repoLocation: URL) -> URL {
        cacheDirectory(for: repoLocation).appending(path: Self.stateFileName)
    }

    private func resumeDataURL(for file: DownloadFile, in repoLocation: URL) -> URL {
        cacheDirectory(for: repoLocation)
            .appending(path: "resume-data")
            .appending(path: file.relativePath + ".resume")
    }

    private func resumeDataExists(for file: DownloadFile, in repoLocation: URL) -> Bool {
        fileManager.fileExists(atPath: resumeDataURL(for: file, in: repoLocation).path)
    }

    private func persistResumeData(
        _ data: Data,
        for relativePath: String,
        in repoLocation: URL
    ) {
        let url = cacheDirectory(for: repoLocation)
            .appending(path: "resume-data")
            .appending(path: relativePath + ".resume")

        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            AppDiagnostics.shared.record(
                "Failed to persist background model resume data",
                category: "download",
                metadata: [
                    "file": relativePath,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func removeResumeData(
        for relativePath: String,
        in repoLocation: URL
    ) {
        let url = cacheDirectory(for: repoLocation)
            .appending(path: "resume-data")
            .appending(path: relativePath + ".resume")
        try? fileManager.removeItem(at: url)
    }

    private func selfHealMarkerURL(for relativePath: String, in repoLocation: URL) -> URL {
        cacheDirectory(for: repoLocation)
            .appending(path: "resume-data")
            .appending(path: relativePath + ".selfheal")
    }

    private func markSelfHealAttempted(for relativePath: String, in repoLocation: URL) {
        let url = selfHealMarkerURL(for: relativePath, in: repoLocation)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url, options: .atomic)
    }

    private func selfHealAlreadyAttempted(for relativePath: String, in repoLocation: URL) -> Bool {
        fileManager.fileExists(atPath: selfHealMarkerURL(for: relativePath, in: repoLocation).path)
    }

    private func clearSelfHealMarker(for relativePath: String, in repoLocation: URL) {
        try? fileManager.removeItem(at: selfHealMarkerURL(for: relativePath, in: repoLocation))
    }

    private func currentTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func cancelTasks(repositoryID: String) async throws {
        let tasks = await currentTasks()
        let scopedTasks = tasks.filter { task in
            guard let descriptor = Self.parseTaskDescription(task.taskDescription) else {
                return false
            }
            return descriptor.repositoryID == repositoryID
        }
        scopedTasks.forEach { $0.cancel() }
    }

    private func finishBackgroundEventsIfNeeded() {
        completionHandlerLock.lock()
        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        completionHandlerLock.unlock()
        // UIKit requires the background-events completion handler be invoked on the
        // main thread; this delegate callback runs on the session's background queue.
        guard let completionHandler else { return }
        DispatchQueue.main.async {
            completionHandler()
        }
    }
}

extension BackgroundModelDownloadCoordinator: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let descriptor = Self.parseTaskDescription(downloadTask.taskDescription) else {
            return
        }

        let hub = HubApi.shared
        guard let state = loadState(using: hub, repositoryID: descriptor.repositoryID) else {
            return
        }

        let repoLocation = hub.localRepoLocation(Hub.Repo(id: state.manifest.repositoryID))
        let destination = repoLocation.appending(path: descriptor.relativePath)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: location, to: destination)

            if let file = state.manifest.files.first(where: { $0.relativePath == descriptor.relativePath }) {
                try verifyDownloadedFile(file, at: destination)
            }

            removeResumeData(for: descriptor.relativePath, in: repoLocation)
            clearSelfHealMarker(for: descriptor.relativePath, in: repoLocation)
            updateLastError(nil, repositoryID: descriptor.repositoryID)
        } catch {
            // The system temp file at `location` is consumed once this delegate
            // returns. Whether the failure was a move error, size mismatch, or
            // hash mismatch, clear any partial/corrupt destination and re-enqueue
            // the file once so the next pass downloads a clean copy.
            updateLastError(error.localizedDescription, repositoryID: descriptor.repositoryID)
            selfHealFailedFinish(
                file: state.manifest.files.first(where: { $0.relativePath == descriptor.relativePath }),
                repositoryID: descriptor.repositoryID,
                relativePath: descriptor.relativePath,
                destination: destination,
                repoLocation: repoLocation
            )
        }
    }

    private func selfHealFailedFinish(
        file: DownloadFile?,
        repositoryID: String,
        relativePath: String,
        destination: URL,
        repoLocation: URL
    ) {
        // Remove any partial/corrupt file left at the destination so the missing
        // file is detected as incomplete and a re-download can take its place.
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        // Stale resume data would resume a download we just deemed broken; drop it
        // so the re-enqueue starts cleanly from the source URL.
        removeResumeData(for: relativePath, in: repoLocation)

        guard let file, let url = URL(string: file.sourceURL) else {
            AppDiagnostics.shared.record(
                "Unable to self-heal failed background model download",
                category: "download",
                metadata: [
                    "file": relativePath,
                    "repository": repositoryID
                ]
            )
            return
        }

        // Re-enqueue at most once per failure to avoid an infinite loop when the
        // cause is persistent (e.g. an unwritable destination or a server that
        // keeps returning a wrong-sized file). The marker is cleared on success.
        guard !selfHealAlreadyAttempted(for: relativePath, in: repoLocation) else {
            AppDiagnostics.shared.record(
                "Skipped repeat self-heal for background model download",
                category: "download",
                metadata: ["file": relativePath]
            )
            return
        }
        markSelfHealAttempted(for: relativePath, in: repoLocation)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.taskDescription(
            repositoryID: repositoryID,
            relativePath: relativePath
        )
        task.resume()

        AppDiagnostics.shared.record(
            "Re-enqueued background model download after failed file move",
            category: "download",
            metadata: ["file": relativePath]
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            return
        }

        guard let descriptor = Self.parseTaskDescription(task.taskDescription) else {
            return
        }

        let hub = HubApi.shared
        guard let state = loadState(using: hub, repositoryID: descriptor.repositoryID) else {
            return
        }

        let repoLocation = hub.localRepoLocation(Hub.Repo(id: state.manifest.repositoryID))
        let relativePath = descriptor.relativePath

        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            persistResumeData(resumeData, for: relativePath, in: repoLocation)
        }

        updateLastError(error.localizedDescription, repositoryID: descriptor.repositoryID)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishBackgroundEventsIfNeeded()
    }
}
