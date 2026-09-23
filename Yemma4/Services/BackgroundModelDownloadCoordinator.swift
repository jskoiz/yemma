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
        return "Not enough storage: Yemma needs about \(neededGB) free to download the model. Free up some space and try again."
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
        var verifiedFiles: [String: ModelDownloadVerificationReceipt]
        var receivedBytes: [String: Int64]
        var allowsCellularDownload: Bool

        init(
            manifest: DownloadManifest,
            lastError: String?,
            verifiedFiles: [String: ModelDownloadVerificationReceipt] = [:],
            receivedBytes: [String: Int64] = [:],
            allowsCellularDownload: Bool = false
        ) {
            self.manifest = manifest
            self.lastError = lastError
            self.verifiedFiles = verifiedFiles
            self.receivedBytes = receivedBytes
            self.allowsCellularDownload = allowsCellularDownload
        }

        private enum CodingKeys: String, CodingKey {
            case manifest
            case lastError
            case verifiedFiles
            case receivedBytes
            case allowsCellularDownload
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            manifest = try container.decode(DownloadManifest.self, forKey: .manifest)
            lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            verifiedFiles = try container.decodeIfPresent(
                [String: ModelDownloadVerificationReceipt].self,
                forKey: .verifiedFiles
            ) ?? [:]
            receivedBytes = try container.decodeIfPresent([String: Int64].self, forKey: .receivedBytes) ?? [:]
            allowsCellularDownload = try container.decodeIfPresent(Bool.self, forKey: .allowsCellularDownload) ?? false
        }
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
    private let stateTransactionLock = NSLock()
    private let completionHandlerLock = NSLock()
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        // Keep the session permissive so each request can apply the user's
        // current cellular preference. Requests default to Wi-Fi-only below.
        configuration.allowsCellularAccess = true
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
        matching patterns: [String],
        allowsCellularDownload: Bool = false
    ) async throws -> BackgroundModelDownloadSnapshot {
        _ = session

        let manifest = try await persistedOrFreshManifest(
            using: hub,
            repositoryID: repositoryID,
            revision: revision,
            matching: patterns,
            allowsCellularDownload: allowsCellularDownload
        )

        try ensureSufficientStorage(for: manifest, hub: hub)

        try await enqueueMissingTasks(
            using: manifest,
            hub: hub,
            allowsCellularDownload: allowsCellularDownload
        )
        return await snapshot(using: hub, repositoryID: repositoryID)
    }

    private func ensureSufficientStorage(
        for manifest: DownloadManifest,
        hub: HubApi
    ) throws {
        // Only the not-yet-downloaded files will consume new space.
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: manifest.repositoryID))
        let state = loadState(using: hub, repositoryID: manifest.repositoryID)
        let remainingBytes = manifest.files.reduce(into: Int64(0)) { partialResult, file in
            guard !completedFileExists(file, in: repoLocation, state: state) else {
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
            updateLastError(message, repositoryID: manifest.repositoryID, using: hub)
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
            if completedFileExists(file, in: repoLocation, state: persistedState) {
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
                completedBytes += min(
                    max(persistedState.receivedBytes[file.relativePath] ?? 0, 0),
                    file.expectedBytes
                )
                continue
            }

            completedBytes += min(
                max(persistedState.receivedBytes[file.relativePath] ?? 0, 0),
                file.expectedBytes
            )
        }

        let isComplete = manifest.files.allSatisfy {
            completedFileExists($0, in: repoLocation, state: persistedState)
        }
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
        await cancelTasks(repositoryID: repositoryID, using: hub)
        try? fileManager.removeItem(at: cacheDirectory(for: repoLocation))
    }

    /// Removes transient resume and byte-progress state while retaining the
    /// manifest and verified receipts for a ready cached model.
    func clearTransientState(using hub: HubApi, repositoryID: String) async {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: repositoryID))
        await cancelTasks(repositoryID: repositoryID, using: hub)
        try? fileManager.removeItem(at: cacheDirectory(for: repoLocation).appending(path: "resume-data"))
        withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            state?.lastError = nil
            state?.receivedBytes.removeAll()
        }
    }

    /// Verifies the on-disk files against the persisted manifest before the
    /// model directory is offered to the runtime. A matching receipt avoids a
    /// second full hash when the file identity has not changed; a changed or
    /// missing receipt is rehashed and invalid files are removed for repair.
    func verifyCachedFiles(
        using hub: HubApi,
        repositoryID: String,
        revision: String
    ) async -> Bool {
        guard let state = loadState(using: hub, repositoryID: repositoryID),
              state.manifest.revision == revision else {
            return false
        }

        let repoLocation = hub.localRepoLocation(Hub.Repo(id: repositoryID))
        let manifest = state.manifest
        let result = await Task.detached(priority: .utility) {
            var receipts: [String: ModelDownloadVerificationReceipt] = [:]
            var invalidFiles: [String] = []

            for file in manifest.files {
                let destination = repoLocation.appending(path: file.relativePath)
                if let receipt = state.verifiedFiles[file.relativePath],
                   ModelDownloadIntegrity.receiptMatches(
                       receipt,
                       fileAt: destination,
                       revision: manifest.revision,
                       expectedBytes: file.expectedBytes,
                       etag: file.etag
                   ) {
                    receipts[file.relativePath] = receipt
                    continue
                }

                do {
                    receipts[file.relativePath] = try ModelDownloadIntegrity.verify(
                        fileAt: destination,
                        expectedBytes: file.expectedBytes,
                        etag: file.etag,
                        revision: manifest.revision
                    )
                } catch {
                    invalidFiles.append(file.relativePath)
                }
            }

            return (receipts: receipts, invalidFiles: invalidFiles)
        }.value

        return withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            guard var currentState = state,
                  currentState.manifest.revision == revision else {
                return false
            }

            var invalidFiles = Set(result.invalidFiles)
            for file in manifest.files {
                let relativePath = file.relativePath
                let destination = repoLocation.appending(path: relativePath)

                // A delegate callback may have published a newer verified file
                // while the detached validation pass was reading the old one.
                // Preserve that receipt instead of replacing it with stale
                // validation output.
                if let currentReceipt = currentState.verifiedFiles[relativePath],
                   ModelDownloadIntegrity.receiptMatches(
                       currentReceipt,
                       fileAt: destination,
                       revision: revision,
                       expectedBytes: file.expectedBytes,
                       etag: file.etag
                   ) {
                    invalidFiles.remove(relativePath)
                    continue
                }

                if let receipt = result.receipts[relativePath],
                   ModelDownloadIntegrity.receiptMatches(
                       receipt,
                       fileAt: destination,
                       revision: revision,
                       expectedBytes: file.expectedBytes,
                       etag: file.etag
                   ) {
                    currentState.verifiedFiles[relativePath] = receipt
                    invalidFiles.remove(relativePath)
                    continue
                }

                currentState.verifiedFiles.removeValue(forKey: relativePath)
                currentState.receivedBytes.removeValue(forKey: relativePath)
                invalidFiles.insert(relativePath)
                try? fileManager.removeItem(at: destination)
            }

            if invalidFiles.isEmpty {
                currentState.lastError = nil
            } else {
                currentState.lastError = "One or more saved model files failed integrity verification. They will be downloaded again."
            }
            state = currentState
            return invalidFiles.isEmpty
        }
    }

    /// Forces every cached file to be treated as incomplete after a structural
    /// asset-contract failure, so a retry actually replaces same-size files.
    func invalidateCachedFiles(using hub: HubApi, repositoryID: String, reason: String) {
        withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            state?.verifiedFiles.removeAll()
            state?.receivedBytes.removeAll()
            state?.lastError = reason
        }
    }

    func pauseDownload(using hub: HubApi, repositoryID: String) async -> BackgroundModelDownloadSnapshot {
        await cancelTasks(repositoryID: repositoryID, using: hub, producingResumeData: true)
        updateLastError(nil, repositoryID: repositoryID, using: hub)
        return await snapshot(using: hub, repositoryID: repositoryID)
    }

    func cancelDownload(using hub: HubApi, repositoryID: String) async -> BackgroundModelDownloadSnapshot {
        await cancelTasks(repositoryID: repositoryID, using: hub)
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: repositoryID))
        withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            guard state != nil else { return }
            for file in state!.manifest.files {
                removeResumeData(for: file.relativePath, in: repoLocation)
                if !completedFileExists(file, in: repoLocation, state: state!) {
                    state!.receivedBytes.removeValue(forKey: file.relativePath)
                }
            }
            state!.lastError = nil
        }
        return await snapshot(using: hub, repositoryID: repositoryID)
    }

    private func persistedOrFreshManifest(
        using hub: HubApi,
        repositoryID: String,
        revision: String,
        matching patterns: [String],
        allowsCellularDownload: Bool
    ) async throws -> DownloadManifest {
        let repo = Hub.Repo(id: repositoryID)
        let repoLocation = hub.localRepoLocation(repo)

        if let persistedState = loadState(using: hub, repositoryID: repositoryID),
            persistedState.manifest.repositoryID == repositoryID,
            persistedState.manifest.revision == revision
        {
            if persistedState.allowsCellularDownload != allowsCellularDownload {
                await cancelTasks(repositoryID: repositoryID, using: hub)
                try? fileManager.removeItem(
                    at: cacheDirectory(for: repoLocation).appending(path: "resume-data")
                )
                return withStateTransaction(using: hub, repositoryID: repositoryID) { state in
                    guard var currentState = state,
                          currentState.manifest.repositoryID == repositoryID,
                          currentState.manifest.revision == revision else {
                        return persistedState.manifest
                    }
                    currentState.allowsCellularDownload = allowsCellularDownload
                    currentState.receivedBytes.removeAll()
                    state = currentState
                    return currentState.manifest
                }
            }
            return persistedState.manifest
        }

        await cancelTasks(repositoryID: repositoryID, using: hub)
        try? fileManager.removeItem(at: cacheDirectory(for: repoLocation))

        let manifest = try await buildManifest(
            using: hub,
            repositoryID: repositoryID,
            revision: revision,
            matching: patterns
        )
        withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            state = PersistedState(
                manifest: manifest,
                lastError: nil,
                allowsCellularDownload: allowsCellularDownload
            )
        }
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
        hub: HubApi,
        allowsCellularDownload: Bool
    ) async throws {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: manifest.repositoryID))
        guard let state = loadState(using: hub, repositoryID: manifest.repositoryID) else {
            return
        }
        let existingTasks = await currentTasks()
        let existingTaskDescriptions = Set(
            existingTasks
                .filter { $0.state == .running || $0.state == .suspended }
                .compactMap(\.taskDescription)
        )

        for file in manifest.files {
            if completedFileExists(file, in: repoLocation, state: state) {
                continue
            }

            if existingTaskDescriptions.contains(
                Self.taskDescription(repositoryID: manifest.repositoryID, relativePath: file.relativePath)
            ) {
                continue
            }

            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeDataURL(for: file, in: repoLocation)), !resumeData.isEmpty {
                task = session.downloadTask(withResumeData: resumeData)
                rememberResumedTask(task)
            } else {
                guard let url = URL(string: file.sourceURL) else {
                    // A file we cannot turn into a task would silently never download,
                    // leaving the bundle incomplete with no pending work. Surface it.
                    updateLastError(
                        "Invalid download URL for \(file.relativePath).",
                        repositoryID: manifest.repositoryID,
                        using: hub
                    )
                    AppDiagnostics.shared.record(
                        "Skipped background model download with invalid source URL",
                        category: "download",
                        metadata: [
                            "file": file.relativePath,
                            "repository": manifest.repositoryID
                        ]
                    )
                    continue
                }

                let request = makeRequest(url: url, allowsCellularDownload: allowsCellularDownload)
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
    private func verifyDownloadedFile(
        _ file: DownloadFile,
        at destination: URL,
        revision: String
    ) throws -> ModelDownloadVerificationReceipt {
        do {
            return try ModelDownloadIntegrity.verify(
                fileAt: destination,
                expectedBytes: file.expectedBytes,
                etag: file.etag,
                revision: revision
            )
        } catch {
            throw Hub.HubClientError.downloadError(
                "Downloaded file verification failed for \(file.relativePath): \(error.localizedDescription)"
            )
        }
    }

    private func completedFileExists(
        _ file: DownloadFile,
        in repoLocation: URL,
        state: PersistedState?
    ) -> Bool {
        let destination = repoLocation.appending(path: file.relativePath)
        guard fileManager.fileExists(atPath: destination.path) else {
            return false
        }

        guard let state,
              let receipt = state.verifiedFiles[file.relativePath] else {
            return false
        }

        return ModelDownloadIntegrity.receiptMatches(
            receipt,
            fileAt: destination,
            revision: state.manifest.revision,
            expectedBytes: file.expectedBytes,
            etag: file.etag
        )
    }

    private func withStateTransaction<T>(
        using hub: HubApi,
        repositoryID: String,
        _ body: (inout PersistedState?) -> T
    ) -> T {
        stateTransactionLock.lock()
        defer { stateTransactionLock.unlock() }

        var state = loadStateUnlocked(using: hub, repositoryID: repositoryID)
        let result = body(&state)
        if let state {
            saveStateUnlocked(state, using: hub)
        }
        return result
    }

    private func loadState(using hub: HubApi, repositoryID: String) -> PersistedState? {
        stateTransactionLock.lock()
        defer { stateTransactionLock.unlock() }
        return loadStateUnlocked(using: hub, repositoryID: repositoryID)
    }

    private func loadStateUnlocked(using hub: HubApi, repositoryID: String) -> PersistedState? {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: repositoryID))
        let stateURL = stateURL(for: repoLocation)
        guard let data = try? Data(contentsOf: stateURL) else {
            return nil
        }

        return try? decoder.decode(PersistedState.self, from: data)
    }

    private func saveStateUnlocked(_ state: PersistedState, using hub: HubApi) {
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

    private func updateLastError(_ message: String?, repositoryID: String, using hub: HubApi) {
        withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            state?.lastError = message
        }
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

    private func makeRequest(url: URL, allowsCellularDownload: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allowsCellularAccess = allowsCellularDownload
        request.allowsExpensiveNetworkAccess = allowsCellularDownload
        request.allowsConstrainedNetworkAccess = allowsCellularDownload
        return request
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

    private let progressMetadataLock = NSLock()
    private var lastPersistedProgress: [String: (bytes: Int64, date: Date)] = [:]

    private func persistReceivedBytes(
        _ bytes: Int64,
        for relativePath: String,
        repositoryID: String,
        using hub: HubApi,
        force: Bool
    ) {
        let now = Date()
        let key = "\(repositoryID)|\(relativePath)"
        progressMetadataLock.lock()
        let previous = lastPersistedProgress[key]
        let shouldPersist = force
            || previous == nil
            || bytes - (previous?.bytes ?? 0) >= 1 * 1024 * 1024
            || now.timeIntervalSince(previous?.date ?? .distantPast) >= 1
        if shouldPersist {
            lastPersistedProgress[key] = (bytes: bytes, date: now)
        }
        progressMetadataLock.unlock()

        guard shouldPersist else {
            return
        }
        withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            state?.receivedBytes[relativePath] = max(bytes, 0)
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

    private func enqueueFreshTask(
        file: DownloadFile?,
        repositoryID: String,
        allowsCellularDownload: Bool
    ) {
        guard let file, let url = URL(string: file.sourceURL) else {
            return
        }

        let task = session.downloadTask(
            with: makeRequest(url: url, allowsCellularDownload: allowsCellularDownload)
        )
        task.taskDescription = Self.taskDescription(
            repositoryID: repositoryID,
            relativePath: file.relativePath
        )
        task.resume()
    }

    private func currentTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private let taskMetadataLock = NSLock()
    private var resumedTaskIdentifiers: Set<Int> = []

    private func rememberResumedTask(_ task: URLSessionTask) {
        taskMetadataLock.lock()
        resumedTaskIdentifiers.insert(task.taskIdentifier)
        taskMetadataLock.unlock()
    }

    private func takeResumedTask(_ task: URLSessionTask) -> Bool {
        taskMetadataLock.lock()
        defer { taskMetadataLock.unlock() }
        return resumedTaskIdentifiers.remove(task.taskIdentifier) != nil
    }

    private func cancelTasks(
        repositoryID: String,
        using hub: HubApi,
        producingResumeData: Bool = false
    ) async {
        let tasks = await currentTasks()
        let scopedTasks = tasks.filter { task in
            guard let descriptor = Self.parseTaskDescription(task.taskDescription) else {
                return false
            }
            return descriptor.repositoryID == repositoryID
        }

        for task in scopedTasks where task.state == .running || task.state == .suspended {
            if producingResumeData,
               let downloadTask = task as? URLSessionDownloadTask,
               let descriptor = Self.parseTaskDescription(task.taskDescription) {
                let repoLocation = hub.localRepoLocation(Hub.Repo(id: repositoryID))
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    downloadTask.cancel(byProducingResumeData: { [weak self] resumeData in
                        defer { continuation.resume() }
                        guard let self else { return }
                        if let resumeData, !resumeData.isEmpty {
                            self.persistResumeData(
                                resumeData,
                                for: descriptor.relativePath,
                                in: repoLocation
                            )
                        }
                    })
                }
            } else {
                task.cancel()
            }
        }

        await waitForTasksToDrain(repositoryID: repositoryID)
    }

    private func waitForTasksToDrain(repositoryID: String) async {
        for _ in 0..<200 {
            let tasks = await currentTasks()
            let hasActiveTask = tasks.contains { task in
                guard let descriptor = Self.parseTaskDescription(task.taskDescription),
                      descriptor.repositoryID == repositoryID else {
                    return false
                }
                return task.state == .running || task.state == .suspended || task.state == .canceling
            }
            if !hasActiveTask {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
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
        _ = takeResumedTask(downloadTask)

        let hub = HubApi.shared
        guard let state = loadState(using: hub, repositoryID: descriptor.repositoryID) else {
            return
        }

        let repoLocation = hub.localRepoLocation(Hub.Repo(id: state.manifest.repositoryID))
        let destination = repoLocation.appending(path: descriptor.relativePath)

        do {
            guard let file = state.manifest.files.first(where: { $0.relativePath == descriptor.relativePath }) else {
                throw Hub.HubClientError.downloadError(
                    "Downloaded file was not present in the saved manifest: \(descriptor.relativePath)."
                )
            }

            // Verify the system temporary file before publishing it into the
            // public model directory. Readers can therefore never observe a
            // same-size payload while its digest is still being checked.
            let verifiedReceipt = try verifyDownloadedFile(
                file,
                at: location,
                revision: state.manifest.revision
            )

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: location, to: destination)

            recordVerifiedFile(
                file,
                receipt: verifiedReceipt.updatingModificationDate(from: destination),
                repositoryID: descriptor.repositoryID,
                using: hub
            )

            removeResumeData(for: descriptor.relativePath, in: repoLocation)
            clearSelfHealMarker(for: descriptor.relativePath, in: repoLocation)
            updateLastError(nil, repositoryID: descriptor.repositoryID, using: hub)
        } catch {
            // The system temp file at `location` is consumed once this delegate
            // returns. Whether the failure was a move error, size mismatch, or
            // hash mismatch, clear any partial/corrupt destination and re-enqueue
            // the file once so the next pass downloads a clean copy.
            updateLastError(error.localizedDescription, repositoryID: descriptor.repositoryID, using: hub)
            selfHealFailedFinish(
                file: state.manifest.files.first(where: { $0.relativePath == descriptor.relativePath }),
                repositoryID: descriptor.repositoryID,
                relativePath: descriptor.relativePath,
                destination: destination,
                repoLocation: repoLocation,
                allowsCellularDownload: state.allowsCellularDownload
            )
        }
    }

    private func recordVerifiedFile(
        _ file: DownloadFile,
        receipt: ModelDownloadVerificationReceipt,
        repositoryID: String,
        using hub: HubApi
    ) {
        withStateTransaction(using: hub, repositoryID: repositoryID) { state in
            guard state?.manifest.revision == receipt.revision else {
                return
            }
            state?.verifiedFiles[file.relativePath] = receipt
            state?.receivedBytes.removeValue(forKey: file.relativePath)
            state?.lastError = nil
        }
    }

    private func selfHealFailedFinish(
        file: DownloadFile?,
        repositoryID: String,
        relativePath: String,
        destination: URL,
        repoLocation: URL,
        allowsCellularDownload: Bool
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

        let request = makeRequest(url: url, allowsCellularDownload: allowsCellularDownload)
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
        let wasResumed = takeResumedTask(task)

        persistReceivedBytes(
            max(Int64(task.countOfBytesReceived), 0),
            for: relativePath,
            repositoryID: descriptor.repositoryID,
            using: hub,
            force: true
        )

        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            persistResumeData(resumeData, for: relativePath, in: repoLocation)
        } else if wasResumed && ModelDownloadIntegrity.shouldDiscardResumeData(after: error) {
            // A stale or undecodable resume blob must not strand this file in
            // an endless retry loop. Start one clean request after the old
            // task has fully drained.
            removeResumeData(for: relativePath, in: repoLocation)
            var replacement: (file: DownloadFile, allowsCellularDownload: Bool)?
            withStateTransaction(using: hub, repositoryID: descriptor.repositoryID) { state in
                guard state != nil else { return }
                state!.receivedBytes.removeValue(forKey: relativePath)
                if let file = state!.manifest.files.first(where: { $0.relativePath == relativePath }) {
                    replacement = (file: file, allowsCellularDownload: state!.allowsCellularDownload)
                }
            }
            if let replacement {
                enqueueFreshTask(
                    file: replacement.file,
                    repositoryID: descriptor.repositoryID,
                    allowsCellularDownload: replacement.allowsCellularDownload
                )
            }
        }

        if ModelDownloadIntegrity.shouldDiscardResumeData(after: error) {
            updateLastError(error.localizedDescription, repositoryID: descriptor.repositoryID, using: hub)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let descriptor = Self.parseTaskDescription(downloadTask.taskDescription) else {
            return
        }
        persistReceivedBytes(
            max(totalBytesWritten, 0),
            for: descriptor.relativePath,
            repositoryID: descriptor.repositoryID,
            using: HubApi.shared,
            force: false
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishBackgroundEventsIfNeeded()
    }
}
