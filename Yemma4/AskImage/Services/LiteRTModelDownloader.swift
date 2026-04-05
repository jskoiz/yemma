import Foundation
import Observation

// MARK: - Background session events for LiteRT downloads

/// Receives UIApplication background-session completion handlers for the LiteRT download session.
final class LiteRTBackgroundDownloadEvents: @unchecked Sendable {
    static let shared = LiteRTBackgroundDownloadEvents()

    private let lock = NSLock()
    private var handler: (() -> Void)?

    func setCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func finishPendingEvents() {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?()
    }
}

// MARK: - LiteRT Model Downloader

/// Manages downloading, validation, and deletion of LiteRT-LM models for Ask Image.
///
/// Mirrors the existing `ModelDownloader` patterns:
/// - `@MainActor @Observable` for SwiftUI consumption
/// - Background `URLSession` with a dedicated identifier
/// - Resume data persisted in Caches
/// - Progress throttling (150 ms or 0.5% delta)
/// - Diagnostics logged via `AppDiagnostics` with category "ask_image"
///
/// Storage is fully separate from the GGUF path:
///   `Documents/litert-models/<model-id>/<fileName>`
@MainActor
@Observable
public final class LiteRTModelDownloader: AskImageModelStore {

    // MARK: - Public observable state

    /// Per-model state dictionary, keyed by model ID.
    private(set) var modelStates: [String: LiteRTModelState] = [:]

    /// The model ID currently being downloaded, if any.
    private(set) var activeDownloadModelID: String?

    /// Convenience: last error message for display.
    private(set) var lastError: String?

    // MARK: - AskImageModelStore conformance

    var availableModels: [LiteRTModelDescriptor] {
        LiteRTModelCatalog.allModels
    }

    func state(for modelID: String) -> LiteRTModelState {
        modelStates[modelID] ?? .notDownloaded
    }

    // MARK: - Private

    private let fileManager: FileManager
    private let backgroundSession: LiteRTBackgroundDownloadSession

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.backgroundSession = .shared

        // Seed initial states from on-disk reality.
        for model in LiteRTModelCatalog.allModels {
            modelStates[model.id] = validate(model.id) ? .downloaded : .notDownloaded
        }
    }

    // MARK: - Validation

    /// Check whether a model's local files are intact.
    ///
    /// Validates:
    /// 1. File exists at the expected path
    /// 2. File size > 0
    /// 3. File extension matches the descriptor
    /// 4. (Optional) cached ETag metadata exists
    func validate(_ modelID: String) -> Bool {
        guard let descriptor = LiteRTModelCatalog.model(for: modelID) else { return false }

        let filePath = descriptor.localModelPath.path

        guard fileManager.fileExists(atPath: filePath) else { return false }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: filePath),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0
        else {
            return false
        }

        // Extension check
        let actualExtension = (filePath as NSString).pathExtension
        guard actualExtension == descriptor.expectedExtension else {
            AppDiagnostics.shared.record(
                "LiteRT model extension mismatch",
                category: "ask_image",
                metadata: [
                    "model": modelID,
                    "expected": descriptor.expectedExtension,
                    "actual": actualExtension,
                ]
            )
            return false
        }

        return true
    }

    // MARK: - Download

    func download(_ model: LiteRTModelDescriptor) async throws {
        guard activeDownloadModelID == nil else {
            AppDiagnostics.shared.record(
                "Download rejected: another download in progress",
                category: "ask_image",
                metadata: ["requested": model.id, "active": activeDownloadModelID ?? "?"]
            )
            return
        }

        // If already downloaded and valid, nothing to do.
        if validate(model.id) {
            modelStates[model.id] = .downloaded
            AppDiagnostics.shared.record(
                "Model already downloaded",
                category: "ask_image",
                metadata: ["model": model.id]
            )
            return
        }

        activeDownloadModelID = model.id
        modelStates[model.id] = .downloading(progress: 0)
        lastError = nil

        // Ensure destination directory exists.
        try ensureDirectory(at: model.localDirectory)

        // Look for resume data.
        let resumeData = loadResumeData(for: model)

        AppDiagnostics.shared.record(
            "Starting LiteRT model download",
            category: "ask_image",
            metadata: [
                "model": model.id,
                "hasResumeData": resumeData != nil,
                "expectedBytes": model.expectedBytes,
            ]
        )

        let status = await backgroundSession.startOrReconnect(
            downloadURL: model.downloadURL,
            destinationURL: model.localModelPath,
            resumeData: resumeData,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.handleProgress(progress, for: model.id)
                }
            },
            completionHandler: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleCompletion(result, for: model)
                }
            }
        )

        switch status {
        case let .active(progress):
            modelStates[model.id] = .downloading(progress: progress)
        case .completed:
            finishDownload(for: model)
        case .idle:
            activeDownloadModelID = nil
            modelStates[model.id] = .notDownloaded
        }
    }

    /// Attempt to reconnect to an in-flight background download after app relaunch.
    func reconnectIfNeeded() async {
        guard activeDownloadModelID == nil else { return }

        for model in LiteRTModelCatalog.allModels {
            if validate(model.id) {
                modelStates[model.id] = .downloaded
                continue
            }

            // Check if there is resume data, suggesting a previous download was in progress.
            let hasResumeData = fileManager.fileExists(atPath: model.resumeDataPath.path)

            let status = await backgroundSession.observeExisting(
                downloadURL: model.downloadURL,
                destinationURL: model.localModelPath,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.handleProgress(progress, for: model.id)
                    }
                },
                completionHandler: { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.handleCompletion(result, for: model)
                    }
                }
            )

            switch status {
            case let .active(progress):
                activeDownloadModelID = model.id
                modelStates[model.id] = .downloading(progress: progress)
                AppDiagnostics.shared.record(
                    "Reconnected to background LiteRT download",
                    category: "ask_image",
                    metadata: ["model": model.id, "progress": progress]
                )
                return // Only one download at a time.
            case .completed:
                finishDownload(for: model)
            case .idle:
                if hasResumeData {
                    modelStates[model.id] = .notDownloaded
                }
            }
        }
    }

    // MARK: - Cancel

    func cancelDownload(_ modelID: String) {
        guard activeDownloadModelID == modelID else { return }

        backgroundSession.cancelActiveDownload()
        activeDownloadModelID = nil
        modelStates[modelID] = .notDownloaded

        AppDiagnostics.shared.record(
            "LiteRT download cancelled",
            category: "ask_image",
            metadata: ["model": modelID]
        )
    }

    // MARK: - Delete

    func deleteModel(_ modelID: String) throws {
        guard let descriptor = LiteRTModelCatalog.model(for: modelID) else { return }

        // Cancel if currently downloading.
        if activeDownloadModelID == modelID {
            cancelDownload(modelID)
        }

        // Remove the model directory.
        let dir = descriptor.localDirectory
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }

        // Remove resume data.
        clearResumeData(for: descriptor)

        modelStates[modelID] = .notDownloaded
        lastError = nil

        AppDiagnostics.shared.record(
            "Deleted LiteRT model",
            category: "ask_image",
            metadata: ["model": modelID]
        )
    }

    // MARK: - Private helpers

    private func handleProgress(_ progress: Double, for modelID: String) {
        guard activeDownloadModelID == modelID else { return }
        modelStates[modelID] = .downloading(progress: progress)
    }

    private func handleCompletion(_ result: LiteRTDownloadCompletion, for model: LiteRTModelDescriptor) {
        switch result {
        case .success:
            finishDownload(for: model)
        case let .failure(error, resumeData):
            if let resumeData {
                try? resumeData.write(to: model.resumeDataPath, options: [.atomic])
            }

            activeDownloadModelID = nil
            let message = Self.describeError(error)
            lastError = message
            modelStates[model.id] = .failed(reason: message)

            AppDiagnostics.shared.record(
                "LiteRT download failed",
                category: "ask_image",
                metadata: [
                    "model": model.id,
                    "error": message,
                    "hasResumeData": resumeData != nil,
                ]
            )
        }
    }

    private func finishDownload(for model: LiteRTModelDescriptor) {
        clearResumeData(for: model)
        activeDownloadModelID = nil

        if validate(model.id) {
            modelStates[model.id] = .downloaded
            // Persist ETag if the server sent one.
            if let etag = backgroundSession.lastETag {
                try? etag.write(to: model.etagPath, atomically: true, encoding: .utf8)
            }
            AppDiagnostics.shared.record(
                "LiteRT model download complete",
                category: "ask_image",
                metadata: ["model": model.id, "path": model.localModelPath.path]
            )
        } else {
            let reason = "Downloaded file failed validation"
            modelStates[model.id] = .validationFailed(reason: reason)
            lastError = reason
            AppDiagnostics.shared.record(
                "LiteRT model validation failed after download",
                category: "ask_image",
                metadata: ["model": model.id]
            )
        }
    }

    private func ensureDirectory(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func loadResumeData(for model: LiteRTModelDescriptor) -> Data? {
        guard fileManager.fileExists(atPath: model.resumeDataPath.path) else { return nil }
        return try? Data(contentsOf: model.resumeDataPath)
    }

    private func clearResumeData(for model: LiteRTModelDescriptor) {
        if fileManager.fileExists(atPath: model.resumeDataPath.path) {
            try? fileManager.removeItem(at: model.resumeDataPath)
        }
    }

    private static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection. Try again when the network is available."
            case NSURLErrorTimedOut:
                return "The download timed out. Please try again."
            case NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile:
                return "Unable to save the model file on disk."
            case NSURLErrorCancelled:
                return "The download was interrupted. Open the app again to resume."
            default:
                break
            }
        }

        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            return reason
        }
        return nsError.localizedDescription
    }
}

// MARK: - Background URLSession wrapper

private enum LiteRTDownloadCompletion {
    case success
    case failure(Error, resumeData: Data?)
}

private enum LiteRTDownloadStatus {
    case idle
    case active(progress: Double)
    case completed
}

private final class LiteRTBackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LiteRTBackgroundDownloadSession()

    private let identifier = "\(Yemma4AppConfiguration.bundleIdentifier).litert-model-download"
    private let lock = NSLock()
    private let fileManager = FileManager.default

    private(set) var lastETag: String?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var destinationURL: URL?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var completionHandler: (@Sendable (LiteRTDownloadCompletion) -> Void)?
    private var lastReportedProgress: Double = 0
    private var lastProgressUpdate = Date.distantPast

    private override init() {
        super.init()
    }

    // MARK: - Start / reconnect

    func startOrReconnect(
        downloadURL: URL,
        destinationURL: URL,
        resumeData: Data?,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completionHandler: @escaping @Sendable (LiteRTDownloadCompletion) -> Void
    ) async -> LiteRTDownloadStatus {
        setCallbacks(destinationURL: destinationURL, progressHandler: progressHandler, completionHandler: completionHandler)

        if fileManager.fileExists(atPath: destinationURL.path) {
            return .completed
        }

        let tasks = await allTasks()
        if let task = matchingTask(in: tasks, for: downloadURL) {
            let progress = currentProgress(for: task)
            progressHandler(progress)
            return .active(progress: progress)
        }

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: downloadURL)
        }
        task.taskDescription = downloadURL.absoluteString
        task.resume()
        progressHandler(0)
        return .active(progress: 0)
    }

    func observeExisting(
        downloadURL: URL,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completionHandler: @escaping @Sendable (LiteRTDownloadCompletion) -> Void
    ) async -> LiteRTDownloadStatus {
        setCallbacks(destinationURL: destinationURL, progressHandler: progressHandler, completionHandler: completionHandler)

        if fileManager.fileExists(atPath: destinationURL.path) {
            return .completed
        }

        let tasks = await allTasks()
        if let task = matchingTask(in: tasks, for: downloadURL) {
            let progress = currentProgress(for: task)
            progressHandler(progress)
            return .active(progress: progress)
        }

        return .idle
    }

    func cancelActiveDownload() {
        Task {
            let tasks = await allTasks()
            for task in tasks {
                task.cancel()
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))

        lock.lock()
        let now = Date()
        let delta = progress - lastReportedProgress
        let shouldReport = progress >= 1
            || delta >= 0.005
            || now.timeIntervalSince(lastProgressUpdate) >= 0.15
        if shouldReport {
            lastReportedProgress = progress
            lastProgressUpdate = now
        }
        let handler = self.progressHandler
        lock.unlock()

        guard shouldReport else { return }
        handler?(progress)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let dest = self.destinationURL
        let handler = self.completionHandler

        // Capture ETag from server response.
        if let response = downloadTask.response as? HTTPURLResponse,
           let etag = response.value(forHTTPHeaderField: "ETag") {
            self.lastETag = etag
        }
        lock.unlock()

        guard let dest else {
            handler?(.failure(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown),
                resumeData: nil
            ))
            return
        }

        do {
            // Ensure parent directory exists.
            let parentDir = dest.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.moveItem(at: location, to: dest)
            handler?(.success)
        } catch {
            handler?(.failure(error, resumeData: nil))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        lock.lock()
        let handler = self.completionHandler
        lock.unlock()

        handler?(.failure(error, resumeData: resumeData))
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        LiteRTBackgroundDownloadEvents.shared.finishPendingEvents()
    }

    // MARK: - Helpers

    private func setCallbacks(
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completionHandler: @escaping @Sendable (LiteRTDownloadCompletion) -> Void
    ) {
        lock.lock()
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
        self.completionHandler = completionHandler
        lock.unlock()
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func matchingTask(in tasks: [URLSessionTask], for downloadURL: URL) -> URLSessionDownloadTask? {
        tasks
            .compactMap { $0 as? URLSessionDownloadTask }
            .first {
                $0.taskDescription == downloadURL.absoluteString
                    || $0.originalRequest?.url == downloadURL
                    || $0.currentRequest?.url == downloadURL
            }
    }

    private func currentProgress(for task: URLSessionTask) -> Double {
        guard task.countOfBytesExpectedToReceive > 0 else { return 0 }
        return min(1, max(0, Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)))
    }
}
