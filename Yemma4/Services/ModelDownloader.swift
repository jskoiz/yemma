import Foundation
import Observation

@MainActor
@Observable
public final class ModelDownloader {
    public var downloadProgress: Double = 0
    public var isDownloading: Bool = false
    public var isDownloaded: Bool = false
    public var canResumeDownload: Bool = false
    public var error: String?
    public var modelPath: String?

    private let modelDownloadURL = URL(string: "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF/resolve/main/google_gemma-4-E4B-it-Q4_K_M.gguf")!
    private let modelFileName = "gemma-4-e4b-it-q4km.gguf"
    private let resumeDataFileName = "gemma-4-e4b-it-q4km.resume-data"
    private let fileManager: FileManager
    private let backgroundDownloadSession: BackgroundModelDownloadSession

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.backgroundDownloadSession = .shared
    }

    public func validateDownloadedModel() async {
        guard Yemma4AppConfiguration.supportsLocalModelRuntime else {
            isDownloading = false
            isDownloaded = false
            canResumeDownload = false
            downloadProgress = 0
            modelPath = nil
            error = Self.unsupportedRuntimeMessage
            AppDiagnostics.shared.record(
                "Skipped local model validation on unsupported runtime",
                category: "download"
            )
            return
        }

        let fileManager = self.fileManager
        let modelFileURL = self.modelFileURL
        let resumeDataURL = self.resumeDataURL

        let result = ModelDownloaderIO.validateLocalModel(
            fileManager: fileManager,
            modelFileURL: modelFileURL,
            resumeDataURL: resumeDataURL
        )

        isDownloaded = result.isDownloaded
        modelPath = result.modelPath
        canResumeDownload = ModelDownloaderIO.loadResumeDataIfAvailable(
            fileManager: fileManager,
            resumeDataURL: resumeDataURL
        ) != nil
        let restoredDownload = await observeBackgroundDownloadIfNeeded()

        if !isDownloading {
            downloadProgress = result.isDownloaded ? max(downloadProgress, 1) : 0
        }
        AppDiagnostics.shared.record(
            "Validated local model state",
            category: "download",
            metadata: [
                "isDownloaded": result.isDownloaded,
                "modelPath": result.modelPath ?? "nil",
                "canResume": canResumeDownload,
                "restoredDownload": restoredDownload
            ]
        )
    }

    public func downloadModel() async {
        guard Yemma4AppConfiguration.supportsLocalModelRuntime else {
            isDownloading = false
            isDownloaded = false
            canResumeDownload = false
            downloadProgress = 0
            modelPath = nil
            error = Self.unsupportedRuntimeMessage
            AppDiagnostics.shared.record(
                "Blocked model download on unsupported runtime",
                category: "download"
            )
            return
        }

        if isDownloading {
            _ = await observeBackgroundDownloadIfNeeded()
            return
        }

        await validateDownloadedModel()
        error = nil
        AppDiagnostics.shared.record("Starting model download flow", category: "download")

        if isDownloaded, let modelPath {
            downloadProgress = 1
            self.modelPath = modelPath
            AppDiagnostics.shared.record("Model already present", category: "download", metadata: ["path": modelPath])
            return
        }

        isDownloading = true
        downloadProgress = 0

        let fileManager = self.fileManager
        let destinationURL = modelFileURL
        let resumeDataURL = self.resumeDataURL
        let resumeData = ModelDownloaderIO.loadResumeDataIfAvailable(
            fileManager: fileManager,
            resumeDataURL: resumeDataURL
        )

        let startResult = await backgroundDownloadSession.startOrReconnect(
            downloadURL: modelDownloadURL,
            destinationURL: destinationURL,
            resumeData: resumeData,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress
                }
            },
            completionHandler: { [weak self] result in
                Task { @MainActor [weak self] in
                    await self?.handleBackgroundDownloadCompletion(result)
                }
            }
        )

        switch startResult {
        case let .started(progress), let .reconnected(progress):
            downloadProgress = progress
            isDownloading = true
            canResumeDownload = false
            error = nil
            AppDiagnostics.shared.record(
                "Background download active",
                category: "download",
                metadata: [
                    "mode": startResult.modeLabel,
                    "progress": progress
                ]
            )
        case .completed:
            await validateDownloadedModel()
        case .idle:
            isDownloading = false
        }
    }

    public func deleteModel() {
        let urlsToDelete = [modelFileURL, resumeDataURL]
        var lastError: Error?

        for url in urlsToDelete {
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            error = Self.describe(lastError)
            AppDiagnostics.shared.record("Model delete failed", category: "download", metadata: ["error": error ?? "unknown"])
        } else {
            error = nil
            AppDiagnostics.shared.record("Deleted local model files", category: "download")
        }

        Task {
            await validateDownloadedModel()
        }
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var cachesDirectory: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    private var modelFileURL: URL {
        documentsDirectory.appendingPathComponent(modelFileName)
    }

    private var resumeDataURL: URL {
        cachesDirectory.appendingPathComponent(resumeDataFileName)
    }

    private func observeBackgroundDownloadIfNeeded() async -> Bool {
        let status = await backgroundDownloadSession.observeExistingDownload(
            downloadURL: modelDownloadURL,
            destinationURL: modelFileURL,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress
                }
            },
            completionHandler: { [weak self] result in
                Task { @MainActor [weak self] in
                    await self?.handleBackgroundDownloadCompletion(result)
                }
            }
        )

        switch status {
        case let .started(progress), let .reconnected(progress):
            isDownloading = true
            canResumeDownload = false
            error = nil
            downloadProgress = progress
            return true
        case .completed:
            isDownloading = false
            downloadProgress = 1
            isDownloaded = true
            canResumeDownload = false
            modelPath = modelFileURL.path
            return false
        case .idle:
            isDownloading = false
            return false
        }
    }

    private func handleBackgroundDownloadCompletion(_ result: BackgroundDownloadCompletion) async {
        switch result {
        case .success:
            ModelDownloaderIO.clearResumeData(fileManager: fileManager, resumeDataURL: resumeDataURL)
            downloadProgress = 1
            isDownloading = false
            isDownloaded = true
            canResumeDownload = false
            modelPath = modelFileURL.path
            error = nil
            AppDiagnostics.shared.record(
                "Model download completed",
                category: "download",
                metadata: ["path": modelFileURL.path]
            )
        case let .failure(error, resumeData):
            if let resumeData {
                try? resumeData.write(to: resumeDataURL, options: [.atomic])
            }
            isDownloading = false
            canResumeDownload = resumeData != nil
            self.error = Self.describe(error)
            AppDiagnostics.shared.record(
                "Model download failed",
                category: "download",
                metadata: [
                    "error": self.error ?? error.localizedDescription,
                    "hasResumeData": resumeData != nil
                ]
            )
            await validateDownloadedModel()
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection. Try again when the network is available."
            case NSURLErrorTimedOut:
                return "The model download timed out. Please try again."
            case NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile:
                return "Unable to save the model file on disk."
            case NSURLErrorCancelled:
                return "The model download was interrupted. Open the app again to resume."
            default:
                break
            }
        }

        if let localizedDescription = nsError.localizedFailureReason, !localizedDescription.isEmpty {
            return localizedDescription
        }

        return nsError.localizedDescription
    }

    private static let unsupportedRuntimeMessage = "Local GGUF downloads are disabled in the iOS Simulator. Simulator chat uses mocked replies for UI testing; run Yemma on a physical iPhone for real on-device inference."
}

private struct ValidationResult: Sendable {
    let isDownloaded: Bool
    let modelPath: String?
}

private enum ModelDownloaderIO {
    static func loadResumeDataIfAvailable(fileManager: FileManager, resumeDataURL: URL) -> Data? {
        guard fileManager.fileExists(atPath: resumeDataURL.path) else {
            return nil
        }

        return try? Data(contentsOf: resumeDataURL)
    }

    static func clearResumeData(fileManager: FileManager, resumeDataURL: URL) {
        guard fileManager.fileExists(atPath: resumeDataURL.path) else { return }
        try? fileManager.removeItem(at: resumeDataURL)
    }

    static func validateLocalModel(
        fileManager: FileManager,
        modelFileURL: URL,
        resumeDataURL: URL
    ) -> ValidationResult {
        guard fileManager.fileExists(atPath: modelFileURL.path) else {
            clearInvalidModelFile(fileManager: fileManager, modelFileURL: modelFileURL)
            return ValidationResult(isDownloaded: false, modelPath: nil)
        }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: modelFileURL.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0
        else {
            clearInvalidModelFile(fileManager: fileManager, modelFileURL: modelFileURL)
            return ValidationResult(isDownloaded: false, modelPath: nil)
        }

        return ValidationResult(isDownloaded: true, modelPath: modelFileURL.path)
    }

    static func clearInvalidModelFile(fileManager: FileManager, modelFileURL: URL) {
        if fileManager.fileExists(atPath: modelFileURL.path) {
            try? fileManager.removeItem(at: modelFileURL)
        }
    }

    static func persistDownloadedFile(fileManager: FileManager, from tempURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }
}

enum BackgroundDownloadCompletion {
    case success
    case failure(Error, resumeData: Data?)
}

enum BackgroundDownloadStatus {
    case idle
    case started(progress: Double)
    case reconnected(progress: Double)
    case completed

    var modeLabel: String {
        switch self {
        case .started:
            return "started"
        case .reconnected:
            return "reconnected"
        case .completed:
            return "completed"
        case .idle:
            return "idle"
        }
    }
}

final class BackgroundModelDownloadEvents: @unchecked Sendable {
    static let shared = BackgroundModelDownloadEvents()

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

private final class BackgroundModelDownloadSession: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BackgroundModelDownloadSession()

    private let identifier = "\(Yemma4AppConfiguration.bundleIdentifier).model-download"
    private let lock = NSLock()
    private let fileManager = FileManager.default

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var destinationURL: URL?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var completionHandler: (@Sendable (BackgroundDownloadCompletion) -> Void)?
    private var lastReportedProgress: Double = 0
    private var lastProgressUpdate = Date.distantPast

    private override init() {
        super.init()
    }

    func startOrReconnect(
        downloadURL: URL,
        destinationURL: URL,
        resumeData: Data?,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completionHandler: @escaping @Sendable (BackgroundDownloadCompletion) -> Void
    ) async -> BackgroundDownloadStatus {
        setCallbacks(downloadURL: downloadURL, destinationURL: destinationURL, progressHandler: progressHandler, completionHandler: completionHandler)

        if fileManager.fileExists(atPath: destinationURL.path) {
            return .completed
        }

        let tasks = await allTasks()
        if let task = matchingDownloadTask(in: tasks, for: downloadURL) {
            let progress = currentProgress(for: task)
            progressHandler(progress)
            return .reconnected(progress: progress)
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
        return .started(progress: 0)
    }

    func observeExistingDownload(
        downloadURL: URL,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completionHandler: @escaping @Sendable (BackgroundDownloadCompletion) -> Void
    ) async -> BackgroundDownloadStatus {
        setCallbacks(downloadURL: downloadURL, destinationURL: destinationURL, progressHandler: progressHandler, completionHandler: completionHandler)

        if fileManager.fileExists(atPath: destinationURL.path) {
            return .completed
        }

        let tasks = await allTasks()
        if let task = matchingDownloadTask(in: tasks, for: downloadURL) {
            let progress = currentProgress(for: task)
            progressHandler(progress)
            return .reconnected(progress: progress)
        }

        return .idle
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))

        lock.lock()
        let now = Date()
        let progressDelta = progress - lastReportedProgress
        let shouldReport = progress >= 1
            || progressDelta >= 0.005
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

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let destinationURL = self.destinationURL
        let completionHandler = self.completionHandler
        lock.unlock()

        guard let destinationURL else {
            completionHandler?(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown), resumeData: nil))
            return
        }

        do {
            try ModelDownloaderIO.persistDownloadedFile(
                fileManager: fileManager,
                from: location,
                to: destinationURL
            )
            completionHandler?(.success)
        } catch {
            completionHandler?(.failure(error, resumeData: nil))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        lock.lock()
        let completionHandler = self.completionHandler
        lock.unlock()

        completionHandler?(.failure(error, resumeData: resumeData))
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundModelDownloadEvents.shared.finishPendingEvents()
    }

    private func setCallbacks(
        downloadURL: URL,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completionHandler: @escaping @Sendable (BackgroundDownloadCompletion) -> Void
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

    private func matchingDownloadTask(in tasks: [URLSessionTask], for downloadURL: URL) -> URLSessionDownloadTask? {
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
