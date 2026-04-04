import Foundation
import Observation

public struct LocalModelResources: Sendable {
    public let modelPath: String
    public let mmprojPath: String
}

private enum LocalModelAssetKind: String, Sendable {
    case model
    case mmproj
}

private struct LocalModelAsset: Sendable {
    let kind: LocalModelAssetKind
    let downloadURL: URL
    let fileName: String
    let resumeDataFileName: String
    let expectedBytes: Int64
}

private struct ValidationResult: Sendable {
    let isDownloaded: Bool
    let localPath: String?
}

@MainActor
@Observable
public final class ModelDownloader {
    public var downloadProgress: Double = 0
    public var isDownloading: Bool = false
    public var isDownloaded: Bool = false
    public var canResumeDownload: Bool = false
    public var error: String?
    public var modelPath: String?
    public var mmprojPath: String?

    public var localResources: LocalModelResources? {
        guard
            isDownloaded,
            let modelPath,
            let mmprojPath
        else {
            return nil
        }

        return LocalModelResources(modelPath: modelPath, mmprojPath: mmprojPath)
    }

    public var estimatedDownloadBytes: Int64 {
        Self.totalExpectedBytes
    }

    private static let downloadAssets: [LocalModelAsset] = [
        LocalModelAsset(
            kind: .model,
            downloadURL: URL(string: "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF/resolve/main/google_gemma-4-E4B-it-Q4_K_M.gguf")!,
            fileName: "gemma-4-e4b-it-q4km.gguf",
            resumeDataFileName: "gemma-4-e4b-it-q4km.resume-data",
            expectedBytes: 5_405_163_520
        ),
        LocalModelAsset(
            kind: .mmproj,
            downloadURL: URL(string: "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF/resolve/main/mmproj-google_gemma-4-E4B-it-f16.gguf")!,
            fileName: "gemma-4-e4b-it-mmproj-f16.gguf",
            resumeDataFileName: "gemma-4-e4b-it-mmproj-f16.resume-data",
            expectedBytes: 990_372_352
        ),
    ]

    private static let totalExpectedBytes = downloadAssets.reduce(into: Int64(0)) { total, asset in
        total += asset.expectedBytes
    }

    private let fileManager: FileManager
    private let backgroundDownloadSession: BackgroundModelDownloadSession
    private var activeAssetKind: LocalModelAssetKind?

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
            mmprojPath = nil
            activeAssetKind = nil
            error = Self.unsupportedRuntimeMessage
            AppDiagnostics.shared.record(
                "Skipped local model validation on unsupported runtime",
                category: "download"
            )
            return
        }

        refreshLocalState()
        let restoredDownload = await observeBackgroundDownloadIfNeeded()

        if !isDownloading {
            downloadProgress = aggregatedProgress()
        }

        AppDiagnostics.shared.record(
            "Validated local model state",
            category: "download",
            metadata: [
                "isDownloaded": isDownloaded,
                "modelPath": modelPath ?? "nil",
                "mmprojPath": mmprojPath ?? "nil",
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
            mmprojPath = nil
            activeAssetKind = nil
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

        refreshLocalState()
        error = nil
        AppDiagnostics.shared.record("Starting model download flow", category: "download")

        if let localResources {
            downloadProgress = 1
            AppDiagnostics.shared.record(
                "Model assets already present",
                category: "download",
                metadata: [
                    "modelPath": localResources.modelPath,
                    "mmprojPath": localResources.mmprojPath
                ]
            )
            return
        }

        guard let nextAsset = nextPendingAsset() else {
            isDownloading = false
            return
        }

        await startDownload(for: nextAsset)
    }

    public func deleteModel() {
        var lastError: Error?

        for asset in Self.downloadAssets {
            for url in [localFileURL(for: asset), resumeDataURL(for: asset)] {
                do {
                    if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                } catch {
                    lastError = error
                }
            }
        }

        activeAssetKind = nil

        if let lastError {
            error = Self.describe(lastError)
            AppDiagnostics.shared.record("Model delete failed", category: "download", metadata: ["error": error ?? "unknown"])
        } else {
            error = nil
            AppDiagnostics.shared.record("Deleted local model files", category: "download")
        }

        refreshLocalState()
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var cachesDirectory: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    private func localFileURL(for asset: LocalModelAsset) -> URL {
        documentsDirectory.appendingPathComponent(asset.fileName)
    }

    private func resumeDataURL(for asset: LocalModelAsset) -> URL {
        cachesDirectory.appendingPathComponent(asset.resumeDataFileName)
    }

    private func refreshLocalState() {
        let modelResult = ModelDownloaderIO.validateLocalFile(
            fileManager: fileManager,
            fileURL: localFileURL(for: asset(.model))
        )
        let mmprojResult = ModelDownloaderIO.validateLocalFile(
            fileManager: fileManager,
            fileURL: localFileURL(for: asset(.mmproj))
        )

        modelPath = modelResult.localPath
        mmprojPath = mmprojResult.localPath
        isDownloaded = modelResult.isDownloaded && mmprojResult.isDownloaded

        if !isDownloading {
            downloadProgress = aggregatedProgress()
        }

        if let pendingAsset = nextPendingAsset() {
            canResumeDownload = ModelDownloaderIO.loadResumeDataIfAvailable(
                fileManager: fileManager,
                resumeDataURL: resumeDataURL(for: pendingAsset)
            ) != nil
        } else {
            canResumeDownload = false
        }
    }

    private func asset(_ kind: LocalModelAssetKind) -> LocalModelAsset {
        Self.downloadAssets.first(where: { $0.kind == kind })!
    }

    private func nextPendingAsset() -> LocalModelAsset? {
        Self.downloadAssets.first { asset in
            !fileManager.fileExists(atPath: localFileURL(for: asset).path)
        }
    }

    private func aggregatedProgress(
        activeAsset: LocalModelAsset? = nil,
        activeProgress: Double = 0
    ) -> Double {
        var downloadedBytes: Int64 = 0

        for asset in Self.downloadAssets {
            if let activeAsset, activeAsset.kind == asset.kind {
                downloadedBytes += Int64(Double(asset.expectedBytes) * min(max(activeProgress, 0), 1))
                continue
            }

            if fileManager.fileExists(atPath: localFileURL(for: asset).path) {
                downloadedBytes += asset.expectedBytes
            }
        }

        guard Self.totalExpectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(Self.totalExpectedBytes)))
    }

    private func startDownload(for asset: LocalModelAsset) async {
        activeAssetKind = asset.kind
        isDownloading = true
        canResumeDownload = false
        error = nil
        downloadProgress = aggregatedProgress(activeAsset: asset, activeProgress: 0)

        let resumeData = ModelDownloaderIO.loadResumeDataIfAvailable(
            fileManager: fileManager,
            resumeDataURL: resumeDataURL(for: asset)
        )

        let startResult = await backgroundDownloadSession.startOrReconnect(
            downloadURL: asset.downloadURL,
            destinationURL: localFileURL(for: asset),
            resumeData: resumeData,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = self?.aggregatedProgress(activeAsset: asset, activeProgress: progress) ?? progress
                }
            },
            completionHandler: { [weak self] result in
                Task { @MainActor [weak self] in
                    await self?.handleBackgroundDownloadCompletion(result, for: asset)
                }
            }
        )

        switch startResult {
        case let .started(progress), let .reconnected(progress):
            downloadProgress = aggregatedProgress(activeAsset: asset, activeProgress: progress)
            isDownloading = true
            canResumeDownload = false
            AppDiagnostics.shared.record(
                "Background download active",
                category: "download",
                metadata: [
                    "mode": startResult.modeLabel,
                    "asset": asset.kind.rawValue,
                    "progress": progress
                ]
            )
        case .completed:
            await handleSuccessfulAssetDownload(asset)
        case .idle:
            isDownloading = false
            activeAssetKind = nil
        }
    }

    private func observeBackgroundDownloadIfNeeded() async -> Bool {
        guard let asset = nextPendingAsset() else {
            isDownloading = false
            activeAssetKind = nil
            return false
        }

        activeAssetKind = asset.kind
        let status = await backgroundDownloadSession.observeExistingDownload(
            downloadURL: asset.downloadURL,
            destinationURL: localFileURL(for: asset),
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = self?.aggregatedProgress(activeAsset: asset, activeProgress: progress) ?? progress
                }
            },
            completionHandler: { [weak self] result in
                Task { @MainActor [weak self] in
                    await self?.handleBackgroundDownloadCompletion(result, for: asset)
                }
            }
        )

        switch status {
        case let .started(progress), let .reconnected(progress):
            isDownloading = true
            canResumeDownload = false
            error = nil
            downloadProgress = aggregatedProgress(activeAsset: asset, activeProgress: progress)
            return true
        case .completed:
            await handleSuccessfulAssetDownload(asset)
            return false
        case .idle:
            isDownloading = false
            activeAssetKind = nil
            return false
        }
    }

    private func handleSuccessfulAssetDownload(_ asset: LocalModelAsset) async {
        ModelDownloaderIO.clearResumeData(fileManager: fileManager, resumeDataURL: resumeDataURL(for: asset))
        activeAssetKind = nil
        error = nil
        refreshLocalState()

        AppDiagnostics.shared.record(
            "Model asset download completed",
            category: "download",
            metadata: [
                "asset": asset.kind.rawValue,
                "path": localFileURL(for: asset).path
            ]
        )

        if let nextAsset = nextPendingAsset() {
            await startDownload(for: nextAsset)
            return
        }

        isDownloading = false
        canResumeDownload = false
        downloadProgress = 1
    }

    private func handleBackgroundDownloadCompletion(
        _ result: BackgroundDownloadCompletion,
        for asset: LocalModelAsset
    ) async {
        switch result {
        case .success:
            await handleSuccessfulAssetDownload(asset)
        case let .failure(error, resumeData):
            if let resumeData {
                try? resumeData.write(to: resumeDataURL(for: asset), options: [.atomic])
            }

            isDownloading = false
            activeAssetKind = nil
            refreshLocalState()
            self.error = Self.describe(error)

            AppDiagnostics.shared.record(
                "Model download failed",
                category: "download",
                metadata: [
                    "asset": asset.kind.rawValue,
                    "error": self.error ?? error.localizedDescription,
                    "hasResumeData": resumeData != nil
                ]
            )
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

    static func validateLocalFile(
        fileManager: FileManager,
        fileURL: URL
    ) -> ValidationResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            clearInvalidFile(fileManager: fileManager, fileURL: fileURL)
            return ValidationResult(isDownloaded: false, localPath: nil)
        }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0
        else {
            clearInvalidFile(fileManager: fileManager, fileURL: fileURL)
            return ValidationResult(isDownloaded: false, localPath: nil)
        }

        return ValidationResult(isDownloaded: true, localPath: fileURL.path)
    }

    static func clearInvalidFile(fileManager: FileManager, fileURL: URL) {
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
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
