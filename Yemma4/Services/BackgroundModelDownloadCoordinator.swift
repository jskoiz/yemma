import Foundation
@preconcurrency import Hub

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
        let createdAt: Date
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

        try await enqueueMissingTasks(using: manifest, hub: hub)
        return await snapshot(using: hub)
    }

    func snapshot(using hub: HubApi) async -> BackgroundModelDownloadSnapshot {
        guard let persistedState = loadState(using: hub) else {
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
        let runningTasks = tasks.filter { $0.state == .running || $0.state == .suspended }
        let taskMap: [String: URLSessionTask] = tasks.reduce(into: [:]) { partialResult, task in
            guard let relativePath = task.taskDescription else {
                return
            }
            partialResult[relativePath] = task
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

    func clearState(using hub: HubApi) async {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: Gemma4MLXSupport.repositoryID))
        try? await cancelAllTasks()
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

        if let persistedState = loadState(using: hub),
            persistedState.manifest.repositoryID == repositoryID,
            persistedState.manifest.revision == revision
        {
            return persistedState.manifest
        }

        try? await cancelAllTasks()
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

        return DownloadManifest(
            repositoryID: repositoryID,
            revision: revision,
            createdAt: Date(),
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

            if existingTaskDescriptions.contains(file.relativePath) {
                continue
            }

            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeDataURL(for: file, in: repoLocation)) {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                guard let url = URL(string: file.sourceURL) else {
                    continue
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                task = session.downloadTask(with: request)
            }

            task.taskDescription = file.relativePath
            task.resume()
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

    private func loadState(using hub: HubApi) -> PersistedState? {
        let repoLocation = hub.localRepoLocation(Hub.Repo(id: Gemma4MLXSupport.repositoryID))
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

    private func updateLastError(
        _ message: String?,
        repositoryID: String
    ) {
        let hub = HubApi.shared
        guard var state = loadState(using: hub) else {
            return
        }
        state.lastError = message
        saveState(state, using: hub)
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

    private func currentTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func cancelAllTasks() async throws {
        let tasks = await currentTasks()
        tasks.forEach { $0.cancel() }
    }

    private func finishBackgroundEventsIfNeeded() {
        completionHandlerLock.lock()
        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        completionHandlerLock.unlock()
        completionHandler?()
    }
}

extension BackgroundModelDownloadCoordinator: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let relativePath = downloadTask.taskDescription else {
            return
        }

        let hub = HubApi.shared
        guard let state = loadState(using: hub) else {
            return
        }

        let repoLocation = hub.localRepoLocation(Hub.Repo(id: state.manifest.repositoryID))
        let destination = repoLocation.appending(path: relativePath)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: location, to: destination)

            if
                let file = state.manifest.files.first(where: { $0.relativePath == relativePath }),
                let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
                let fileSize = attributes[.size] as? NSNumber,
                fileSize.int64Value != file.expectedBytes
            {
                throw Hub.HubClientError.downloadError("Downloaded file size did not match \(relativePath).")
            }

            removeResumeData(for: relativePath, in: repoLocation)
            updateLastError(nil, repositoryID: state.manifest.repositoryID)
        } catch {
            updateLastError(error.localizedDescription, repositoryID: state.manifest.repositoryID)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            return
        }

        let hub = HubApi.shared
        guard let state = loadState(using: hub) else {
            return
        }

        let repoLocation = hub.localRepoLocation(Hub.Repo(id: state.manifest.repositoryID))
        let relativePath = task.taskDescription ?? "unknown"

        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
            task.taskDescription != nil
        {
            persistResumeData(resumeData, for: relativePath, in: repoLocation)
        }

        updateLastError(error.localizedDescription, repositoryID: state.manifest.repositoryID)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishBackgroundEventsIfNeeded()
    }
}
