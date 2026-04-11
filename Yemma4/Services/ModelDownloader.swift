import Foundation
import Observation
@preconcurrency import Hub

public struct LocalModelResources: Sendable {
    public let modelDirectoryPath: String
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
    public var estimatedSecondsRemaining: Double?
    public var currentDownloadSpeedBytesPerSecond: Double?

    private var downloadStartDate: Date?
    private var downloadStartProgress: Double = 0
    private var lastSpeedSampleDate: Date?
    private var lastSpeedSampleBytes: Int64 = 0
    private var currentDownloadedBytes: Int64 = 0
    private var currentEstimatedBytes: Int64 = Gemma4MLXSupport.approximateDownloadBytes
    private var currentDownloadLocation: URL?

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let makeHub: @Sendable () -> HubApi
    @ObservationIgnored private var cachedHub: HubApi?
    @ObservationIgnored private var progressMonitorTask: Task<Void, Never>?

    private static let persistedModelPathKey = "com.avmillabs.yemma4.modelDownloader.modelPath"

    private struct DownloadResolution: Sendable {
        let location: URL
        let validation: ValidatedModelDirectory
        let directorySize: Int64
    }

    public init(
        fileManager: FileManager = .default,
        hubFactory: @escaping @Sendable () -> HubApi = { .shared },
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.makeHub = hubFactory
        restorePersistedState()
    }

    public var localResources: LocalModelResources? {
        guard isDownloaded, let modelPath else {
            return nil
        }

        return LocalModelResources(modelDirectoryPath: modelPath)
    }

    public var estimatedDownloadBytes: Int64 {
        max(currentEstimatedBytes, currentDownloadedBytes)
    }

    public var downloadedBytes: Int64 {
        return currentDownloadedBytes
    }

    public var remainingDownloadBytes: Int64 {
        max(estimatedDownloadBytes - currentDownloadedBytes, 0)
    }

    public var activeDownloadLabel: String {
        if isDownloaded {
            return "Model bundle is ready"
        }

        if isDownloading {
            return "Downloading the Gemma 4 MLX model"
        }

        return "Waiting to download"
    }

    public var activeDownloadDetail: String {
        if isDownloaded {
            return "Everything is saved on this iPhone."
        }

        if isDownloading {
            return "One-time setup"
        }

        return "Yemma needs a one-time local model download before chat is ready."
    }

    public func validateDownloadedModel() async {
        guard Yemma4AppConfiguration.supportsLocalModelRuntime else {
            resetForUnsupportedRuntime()
            AppDiagnostics.shared.record(
                "Skipped local MLX model validation on unsupported runtime",
                category: "download"
            )
            return
        }

        let hub = hubClient()
        let validation: (ValidatedModelDirectory, Int64)? = await Task.detached(priority: .utility) {
            let repositoryIDs = [Gemma4MLXSupport.repositoryID] + Gemma4MLXSupport.legacyRepositoryIDs
            for repositoryID in repositoryIDs {
                let location = hub.localRepoLocation(Hub.Repo(id: repositoryID))
                guard let validatedDirectory = try? ModelDirectoryValidator.validatedDirectory(at: location) else {
                    continue
                }

                return (validatedDirectory, Gemma4MLXSupport.directorySize(at: location))
            }

            return nil
        }.value

        if let validation {
            self.modelPath = validation.0.location.path
            isDownloaded = true
            isDownloading = false
            canResumeDownload = false
            downloadProgress = 1
            currentEstimatedBytes = validation.1
            currentDownloadedBytes = validation.1
            error = nil
            persistState(modelPath: validation.0.location.path)
        } else {
            modelPath = nil
            isDownloaded = false
            isDownloading = false
            canResumeDownload = false
            downloadProgress = 0
            currentDownloadedBytes = 0
            currentEstimatedBytes = Gemma4MLXSupport.approximateDownloadBytes
            error = nil
            clearPersistedState()
        }

        AppDiagnostics.shared.record(
            "Validated local MLX model state",
            category: "download",
            metadata: [
                "isDownloaded": isDownloaded,
                "modelPath": modelPath ?? "nil"
            ]
        )
    }

    public func downloadModel() async {
        guard Yemma4AppConfiguration.supportsLocalModelRuntime else {
            resetForUnsupportedRuntime()
            AppDiagnostics.shared.record(
                "Blocked local MLX model download on unsupported runtime",
                category: "download"
            )
            return
        }

        if isDownloading {
            return
        }

        let hub = hubClient()

        do {
            if let cachedDirectory = await firstValidModelDirectoryAsync(using: hub) {
                finishWithCachedDownload(cachedDirectory)
                return
            }

            await purgeStaleDownloadDirectories(using: hub)
            prepareForDownload(using: hub)

            AppDiagnostics.shared.record(
                "Starting MLX model bundle download",
                category: "download",
                metadata: ["repository": Gemma4MLXSupport.repositoryID]
            )

            let resolution = try await Task.detached(priority: .userInitiated) {
                try await Self.performDownload(
                    hub: hub,
                    progressHandler: { progress, speed in
                        Task { @MainActor [weak self] in
                            self?.apply(progress: progress, speed: speed)
                        }
                    }
                )
            }.value

            finishSuccessfulDownload(resolution)
        } catch {
            finishFailedDownload(error)
        }
    }

    public func deleteModel() {
        do {
            let hub = hubClient()
            for cachedDirectory in allKnownModelDirectories(using: hub) where fileManager.fileExists(atPath: cachedDirectory.path) {
                try fileManager.removeItem(at: cachedDirectory)
            }
            stopProgressMonitor()
            modelPath = nil
            isDownloaded = false
            isDownloading = false
            canResumeDownload = false
            downloadProgress = 0
            currentDownloadedBytes = 0
            currentEstimatedBytes = Gemma4MLXSupport.approximateDownloadBytes
            error = nil
            clearPersistedState()
            AppDiagnostics.shared.record("Deleted local MLX model bundle", category: "download")
        } catch {
            self.error = describe(error)
            AppDiagnostics.shared.record(
                "MLX model delete failed",
                category: "download",
                metadata: ["error": self.error ?? "unknown"]
            )
        }
    }

    private func resetForUnsupportedRuntime() {
        stopProgressMonitor()
        isDownloading = false
        isDownloaded = false
        canResumeDownload = false
        downloadProgress = 0
        modelPath = nil
        currentDownloadedBytes = 0
        currentEstimatedBytes = Gemma4MLXSupport.approximateDownloadBytes
        estimatedSecondsRemaining = nil
        currentDownloadSpeedBytesPerSecond = nil
        currentDownloadLocation = nil
        error = Self.unsupportedRuntimeMessage
        clearPersistedState()
    }

    private func prepareForDownload(using hub: HubApi) {
        stopProgressMonitor()
        isDownloading = true
        isDownloaded = false
        canResumeDownload = false
        error = nil
        downloadProgress = 0
        currentDownloadedBytes = 0
        currentEstimatedBytes = Gemma4MLXSupport.approximateDownloadBytes
        startETA()
        currentDownloadLocation = hub.localRepoLocation(Hub.Repo(id: Gemma4MLXSupport.repositoryID))
        startProgressMonitor()
    }

    private func finishWithCachedDownload(_ cachedDirectory: (ValidatedModelDirectory, Int64)) {
        stopProgressMonitor()
        modelPath = cachedDirectory.0.location.path
        isDownloaded = true
        isDownloading = false
        downloadProgress = 1
        currentEstimatedBytes = cachedDirectory.1
        currentDownloadedBytes = currentEstimatedBytes
        error = nil
        resetETA()
        persistState(modelPath: cachedDirectory.0.location.path)
    }

    private func finishSuccessfulDownload(_ resolution: DownloadResolution) {
        stopProgressMonitor()
        modelPath = resolution.location.path
        isDownloaded = true
        isDownloading = false
        downloadProgress = 1
        currentEstimatedBytes = resolution.directorySize
        currentDownloadedBytes = resolution.directorySize
        error = nil
        resetETA()
        persistState(modelPath: resolution.location.path)
        AppDiagnostics.shared.record(
            "MLX model bundle download completed",
            category: "download",
            metadata: [
                "path": resolution.location.path,
                "bytes": resolution.directorySize,
                "processorConfig": resolution.validation.processorConfigFileName,
                "weightFiles": resolution.validation.weightFileNames.count,
                "indexedWeightFiles": resolution.validation.indexedWeightFileNames.count
            ]
        )
    }

    private func finishFailedDownload(_ error: Error) {
        let message = describe(error)
        stopProgressMonitor()
        self.error = message
        isDownloading = false
        resetETA()
        AppDiagnostics.shared.record(
            "MLX model bundle download failed",
            category: "download",
            metadata: ["error": message]
        )
    }

    private func apply(progress: Progress, speed: Double?) {
        let totalUnitCount = max(progress.totalUnitCount, 0)

        if let speed, speed > 0 {
            currentDownloadSpeedBytesPerSecond = speed
        }

        if totalUnitCount > 0 {
            currentEstimatedBytes = max(currentEstimatedBytes, totalUnitCount)
        } else if currentDownloadLocation == nil && progress.fractionCompleted.isFinite {
            downloadProgress = min(max(progress.fractionCompleted, 0), 1)
        }

        updateETA()
    }

    private func updateETA() {
        guard let speed = currentDownloadSpeedBytesPerSecond, speed > 0 else {
            estimatedSecondsRemaining = nil
            return
        }

        let remainingBytes = max(currentEstimatedBytes - currentDownloadedBytes, 0)
        guard remainingBytes > 0 else {
            estimatedSecondsRemaining = nil
            return
        }

        estimatedSecondsRemaining = Double(remainingBytes) / speed
    }

    private func resetETA() {
        downloadStartDate = nil
        downloadStartProgress = 0
        estimatedSecondsRemaining = nil
        currentDownloadSpeedBytesPerSecond = nil
        lastSpeedSampleDate = nil
        lastSpeedSampleBytes = currentDownloadedBytes
        currentDownloadLocation = nil
    }

    private func startETA() {
        downloadStartDate = Date()
        downloadStartProgress = downloadProgress
        estimatedSecondsRemaining = nil
        currentDownloadSpeedBytesPerSecond = nil
        lastSpeedSampleDate = Date()
        lastSpeedSampleBytes = currentDownloadedBytes
    }

    private func startProgressMonitor() {
        guard let downloadLocation = currentDownloadLocation else {
            return
        }

        progressMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let sampledBytes = await Task.detached(priority: .utility) {
                    guard FileManager.default.fileExists(atPath: downloadLocation.path) else {
                        return Int64(0)
                    }

                    // Hugging Face stages active downloads inside the repo's hidden `.cache`
                    // directory, so the live progress sampler needs to include hidden files.
                    return Gemma4MLXSupport.directorySize(at: downloadLocation, includingHiddenFiles: true)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                self?.applyDiskUsageSample(sampledBytes)
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func stopProgressMonitor() {
        progressMonitorTask?.cancel()
        progressMonitorTask = nil
    }

    private func applyDiskUsageSample(_ sampledBytes: Int64) {
        guard isDownloading else {
            return
        }

        guard sampledBytes > 0 else {
            return
        }

        currentDownloadedBytes = sampledBytes
        currentEstimatedBytes = max(currentEstimatedBytes, Gemma4MLXSupport.approximateDownloadBytes)
        downloadProgress = min(
            max(Double(sampledBytes) / Double(currentEstimatedBytes), 0),
            0.99
        )
        updateETA()
    }

    private func firstValidModelDirectoryAsync(using hub: HubApi) async -> (ValidatedModelDirectory, Int64)? {
        await Task.detached(priority: .utility) {
            let repositoryIDs = [Gemma4MLXSupport.repositoryID] + Gemma4MLXSupport.legacyRepositoryIDs
            for repositoryID in repositoryIDs {
                let location = hub.localRepoLocation(Hub.Repo(id: repositoryID))
                guard let validatedDirectory = try? ModelDirectoryValidator.validatedDirectory(at: location) else {
                    continue
                }
                return (validatedDirectory, Gemma4MLXSupport.directorySize(at: location))
            }

            return nil
        }.value
    }

    private func allKnownModelDirectories(using hub: HubApi) -> [URL] {
        let repositoryIDs = [Gemma4MLXSupport.repositoryID] + Gemma4MLXSupport.legacyRepositoryIDs
        return repositoryIDs.map { hub.localRepoLocation(Hub.Repo(id: $0)) }
    }

    private static func performDownload(
        hub: HubApi,
        progressHandler: @escaping @Sendable (Progress, Double?) -> Void
    ) async throws -> DownloadResolution {
        let location = try await hub.snapshot(
            from: Hub.Repo(id: Gemma4MLXSupport.repositoryID),
            revision: Gemma4MLXSupport.repositoryRevision,
            matching: Gemma4MLXSupport.downloadPatterns,
            progressHandler: progressHandler
        )

        let validation: ValidatedModelDirectory
        do {
            validation = try ModelDirectoryValidator.validatedDirectory(at: location)
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }

        return DownloadResolution(
            location: location,
            validation: validation,
            directorySize: Gemma4MLXSupport.directorySize(at: location)
        )
    }

    private func purgeStaleDownloadDirectories(
        using hub: HubApi,
    ) async {
        let directories = allKnownModelDirectories(using: hub)

        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default

            for cachedDirectory in directories where fileManager.fileExists(atPath: cachedDirectory.path) {
                try? fileManager.removeItem(at: cachedDirectory)
            }
        }.value
    }

    private func describe(_ error: Error) -> String {
        if case Hub.HubClientError.authorizationRequired = error {
            return """
                Yemma could not download the configured Hugging Face model source (\(Gemma4MLXSupport.repositoryID)) because authentication was required. Provide a valid Hugging Face token or switch Yemma to a public model source for first-launch setup.
                """
        }

        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private static let unsupportedRuntimeMessage =
        "Local MLX downloads are disabled in the iOS Simulator. Run Yemma on a physical iPhone for real on-device inference."

    private func restorePersistedState() {
        guard let persistedModelPath = defaults.string(forKey: Self.persistedModelPathKey) else {
            return
        }

        guard fileManager.fileExists(atPath: persistedModelPath) else {
            clearPersistedState()
            return
        }

        modelPath = persistedModelPath
        isDownloaded = true
        downloadProgress = 1
        error = nil
    }

    private func persistState(modelPath: String) {
        defaults.set(modelPath, forKey: Self.persistedModelPathKey)
    }

    private func clearPersistedState() {
        defaults.removeObject(forKey: Self.persistedModelPathKey)
    }

    private func hubClient() -> HubApi {
        if let cachedHub {
            return cachedHub
        }

        let hub = makeHub()
        cachedHub = hub
        return hub
    }
}
