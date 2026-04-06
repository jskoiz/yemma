import Foundation
import Observation
import CryptoKit

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
    public var estimatedSecondsRemaining: Double?

    private var downloadStartDate: Date?
    private var downloadStartProgress: Double = 0

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
            downloadURL: URL(string: "https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF/resolve/main/google_gemma-4-E2B-it-Q4_K_M.gguf")!,
            fileName: "gemma-4-e2b-it-q4km.gguf",
            resumeDataFileName: "gemma-4-e2b-it-q4km.resume-data",
            expectedBytes: 3_715_891_200
        ),
        LocalModelAsset(
            kind: .mmproj,
            downloadURL: URL(string: "https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF/resolve/main/mmproj-google_gemma-4-E2B-it-f16.gguf")!,
            fileName: "gemma-4-e2b-it-mmproj-f16.gguf",
            resumeDataFileName: "gemma-4-e2b-it-mmproj-f16.resume-data",
            expectedBytes: 1_058_930_688
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
            ModelIntegrityCache.clearCachedDigest(for: localFileURL(for: asset))
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
        let modelAsset = asset(.model)
        let mmprojAsset = asset(.mmproj)
        let modelResult = ModelDownloaderIO.validateLocalFile(
            fileManager: fileManager,
            fileURL: localFileURL(for: modelAsset),
            expectedBytes: modelAsset.expectedBytes
        )
        let mmprojResult = ModelDownloaderIO.validateLocalFile(
            fileManager: fileManager,
            fileURL: localFileURL(for: mmprojAsset),
            expectedBytes: mmprojAsset.expectedBytes
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

    private func updateETA() {
        guard let startDate = downloadStartDate, downloadProgress > downloadStartProgress else {
            estimatedSecondsRemaining = nil
            return
        }

        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 2 else {
            estimatedSecondsRemaining = nil
            return
        }

        let progressSinceStart = downloadProgress - downloadStartProgress
        guard progressSinceStart > 0, downloadProgress < 1 else {
            estimatedSecondsRemaining = nil
            return
        }

        let rate = progressSinceStart / elapsed
        let remaining = (1 - downloadProgress) / rate
        estimatedSecondsRemaining = remaining
    }

    private func resetETA() {
        downloadStartDate = nil
        downloadStartProgress = 0
        estimatedSecondsRemaining = nil
    }

    private func startETA() {
        downloadStartDate = Date()
        downloadStartProgress = downloadProgress
        estimatedSecondsRemaining = nil
    }

    private func startDownload(for asset: LocalModelAsset) async {
        activeAssetKind = asset.kind
        isDownloading = true
        canResumeDownload = false
        error = nil
        downloadProgress = aggregatedProgress(activeAsset: asset, activeProgress: 0)
        startETA()

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
                    self?.updateETA()
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
            startETA()
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
                    self?.updateETA()
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
            startETA()
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
        resetETA()
        cacheIntegrityMetadataForDownloadedAssets()
    }

    private func cacheIntegrityMetadataForDownloadedAssets() {
        let assetsToCache = Self.downloadAssets.map { asset in
            (asset, localFileURL(for: asset))
        }

        Task.detached(priority: .utility) {
            for (asset, fileURL) in assetsToCache {
                try? ModelIntegrityCache.cacheDigestIfNeeded(
                    for: fileURL,
                    expectedBytes: asset.expectedBytes,
                    assetName: asset.kind.rawValue
                )
            }
        }
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
            resetETA()
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

    /// GGUF magic bytes: "GGUF" in little-endian (0x46475547).
    private static let ggufMagic: [UInt8] = [0x47, 0x47, 0x55, 0x46]

    static func validateLocalFile(
        fileManager: FileManager,
        fileURL: URL,
        expectedBytes: Int64? = nil
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

        // Validate expected file size when known (catches truncated downloads).
        if let expectedBytes, size.int64Value != expectedBytes {
            AppDiagnostics.shared.record(
                "Model file size mismatch",
                category: "download",
                metadata: [
                    "path": fileURL.lastPathComponent,
                    "expected": expectedBytes,
                    "actual": size.int64Value
                ]
            )
            ModelIntegrityCache.clearCachedDigest(for: fileURL)
            clearInvalidFile(fileManager: fileManager, fileURL: fileURL)
            return ValidationResult(isDownloaded: false, localPath: nil)
        }

        // Validate GGUF magic header.
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            clearInvalidFile(fileManager: fileManager, fileURL: fileURL)
            return ValidationResult(isDownloaded: false, localPath: nil)
        }
        let headerData = handle.readData(ofLength: 4)
        try? handle.close()

        guard headerData.count == 4, Array(headerData) == ggufMagic else {
            AppDiagnostics.shared.record(
                "Invalid GGUF header",
                category: "download",
                metadata: ["path": fileURL.lastPathComponent]
            )
            ModelIntegrityCache.clearCachedDigest(for: fileURL)
            clearInvalidFile(fileManager: fileManager, fileURL: fileURL)
            return ValidationResult(isDownloaded: false, localPath: nil)
        }

        return ValidationResult(isDownloaded: true, localPath: fileURL.path)
    }

    static func clearInvalidFile(fileManager: FileManager, fileURL: URL) {
        ModelIntegrityCache.clearCachedDigest(for: fileURL)
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

struct ModelIntegrityCacheEntry: Codable, Sendable {
    let fileSizeBytes: Int64
    let modifiedAt: TimeInterval
    let sha256: String
}

enum ModelIntegrityCache {
    private static let storageKey = "com.avmillabs.yemma4.integrity-cache"
    private static let lock = NSLock()

    static func cachedSHA256(for fileURL: URL, fileManager: FileManager = .default) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let fileMetadata = currentFileMetadata(for: fileURL, fileManager: fileManager),
              let cache = readCache() else {
            return nil
        }

        guard let entry = cacheEntry(for: fileURL, cache: cache),
              entry.fileSizeBytes == fileMetadata.fileSizeBytes,
              entry.modifiedAt == fileMetadata.modifiedAt else {
            return nil
        }

        return entry.sha256
    }

    static func clearCachedDigest(for fileURL: URL) {
        lock.lock()
        defer { lock.unlock() }

        var cache = readCache() ?? [:]
        let didRemovePrimary = cache.removeValue(forKey: cacheKey(for: fileURL)) != nil
        let didRemoveLegacy = cache.removeValue(forKey: fileURL.path) != nil
        guard didRemovePrimary || didRemoveLegacy else { return }
        writeCache(cache)
    }

    static func cacheDigestIfNeeded(
        for fileURL: URL,
        expectedBytes: Int64? = nil,
        assetName: String
    ) throws {
        guard cachedSHA256(for: fileURL) == nil else { return }

        let fileManager = FileManager.default
        guard let fileMetadata = currentFileMetadata(for: fileURL, fileManager: fileManager) else {
            return
        }

        if let expectedBytes, fileMetadata.fileSizeBytes != expectedBytes {
            return
        }

        let sha256 = try computeSHA256(for: fileURL)

        lock.lock()
        defer { lock.unlock() }

        var cache = readCache() ?? [:]
        let entry = ModelIntegrityCacheEntry(
            fileSizeBytes: fileMetadata.fileSizeBytes,
            modifiedAt: fileMetadata.modifiedAt,
            sha256: sha256
        )
        let didWriteCache: Bool
        if cacheEntry(for: fileURL, cache: cache) == nil {
            cache.removeValue(forKey: fileURL.path)
            cache[cacheKey(for: fileURL)] = entry
            writeCache(cache)
            didWriteCache = true
        } else {
            didWriteCache = false
        }

        guard didWriteCache else { return }

        AppDiagnostics.shared.record(
            "Model asset integrity cached",
            category: "download",
            metadata: [
                "asset": assetName,
                "fileSizeMB": Int(fileMetadata.fileSizeBytes / (1024 * 1024)),
                "sha256": sha256
            ]
        )
    }

    private static func computeSHA256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheKey(for fileURL: URL) -> String {
        fileURL.lastPathComponent
    }

    private static func cacheEntry(
        for fileURL: URL,
        cache: [String: ModelIntegrityCacheEntry]
    ) -> ModelIntegrityCacheEntry? {
        cache[cacheKey(for: fileURL)] ?? cache[fileURL.path]
    }

    private static func currentFileMetadata(
        for fileURL: URL,
        fileManager: FileManager
    ) -> (fileSizeBytes: Int64, modifiedAt: TimeInterval)? {
        guard
            let fileAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let fileSize = fileAttributes[.size] as? NSNumber,
            let modifiedAt = fileAttributes[.modificationDate] as? Date
        else {
            return nil
        }

        return (fileSize.int64Value, modifiedAt.timeIntervalSince1970)
    }

    private static func readCache() -> [String: ModelIntegrityCacheEntry]? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }

        return try? JSONDecoder().decode([String: ModelIntegrityCacheEntry].self, from: data)
    }

    private static func writeCache(_ cache: [String: ModelIntegrityCacheEntry]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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
