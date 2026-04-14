import Foundation
import Observation
@preconcurrency import Hub

private let knownModelRepositoryIDs = [Gemma4MLXSupport.repositoryID] + Gemma4MLXSupport.legacyRepositoryIDs

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

    private var lastSpeedSampleDate: Date?
    private var lastSpeedSampleBytes: Int64 = 0
    private var currentDownloadedBytes: Int64 = 0
    private var currentEstimatedBytes: Int64 = Gemma4MLXSupport.approximateDownloadBytes

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let makeHub: @Sendable () -> HubApi
    @ObservationIgnored private var cachedHub: HubApi?
    @ObservationIgnored private var progressMonitorTask: Task<Void, Never>?

    private static let persistedModelPathKey = "com.avmillabs.yemma4.modelDownloader.modelPath"

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
        currentDownloadedBytes
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

        if canResumeDownload {
            return "Ready to resume setup"
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

        if canResumeDownload {
            return "Resume the saved setup progress."
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
        let validation: (ValidatedModelDirectory, Int64)? = await firstValidModelDirectoryAsync(using: hub)

        if let validation {
            finishWithCachedDownload(validation)
            await BackgroundModelDownloadCoordinator.shared.clearState(using: hub)
        } else {
            let snapshot = await BackgroundModelDownloadCoordinator.shared.snapshot(using: hub)
            applyMissingValidatedModelState(snapshot)
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
                await BackgroundModelDownloadCoordinator.shared.clearState(using: hub)
                return
            }

            await purgeStaleDownloadDirectories(using: hub, preservePrimaryRepository: true)
            prepareForDownload()

            AppDiagnostics.shared.record(
                "Starting MLX model bundle download",
                category: "download",
                metadata: ["repository": Gemma4MLXSupport.repositoryID]
            )

            let snapshot = try await BackgroundModelDownloadCoordinator.shared.startDownload(
                using: hub,
                repositoryID: Gemma4MLXSupport.repositoryID,
                revision: Gemma4MLXSupport.repositoryRevision,
                matching: Gemma4MLXSupport.downloadPatterns
            )

            applyBackgroundSnapshot(snapshot)
            if snapshot.hasRunningTasks {
                startProgressMonitor()
            }
        } catch {
            finishFailedDownload(error)
        }
    }

    public func appDidEnterBackground() {
        stopProgressMonitor()
        AppDiagnostics.shared.record(
            "App entered background during MLX setup",
            category: "download",
            metadata: ["isDownloading": isDownloading]
        )
    }

    public func appDidBecomeActive() async {
        await validateDownloadedModel()
        if isDownloading {
            startProgressMonitor()
        }
    }

    public func deleteModel() {
        let hub = hubClient()
        stopProgressMonitor()

        Task { @MainActor [weak self] in
            guard let self else { return }

            await BackgroundModelDownloadCoordinator.shared.clearState(using: hub)

            do {
                for cachedDirectory in self.allKnownModelDirectories(using: hub) where self.fileManager.fileExists(atPath: cachedDirectory.path) {
                    try self.fileManager.removeItem(at: cachedDirectory)
                }

                self.modelPath = nil
                self.isDownloaded = false
                self.isDownloading = false
                self.canResumeDownload = false
                self.downloadProgress = 0
                self.currentDownloadedBytes = 0
                self.currentEstimatedBytes = Gemma4MLXSupport.approximateDownloadBytes
                self.error = nil
                self.resetETA()
                self.clearPersistedState()
                AppDiagnostics.shared.record("Deleted local MLX model bundle", category: "download")
            } catch {
                self.error = self.describe(error)
                AppDiagnostics.shared.record(
                    "MLX model delete failed",
                    category: "download",
                    metadata: ["error": self.error ?? "unknown"]
                )
            }
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
        error = Self.unsupportedRuntimeMessage
        clearPersistedState()
    }

    private func prepareForDownload() {
        stopProgressMonitor()
        isDownloading = true
        isDownloaded = false
        canResumeDownload = false
        error = nil
        downloadProgress = 0
        currentDownloadedBytes = 0
        currentEstimatedBytes = Gemma4MLXSupport.approximateDownloadBytes
        startETA()
    }

    private func finishWithCachedDownload(_ cachedDirectory: (ValidatedModelDirectory, Int64)) {
        stopProgressMonitor()
        modelPath = cachedDirectory.0.location.path
        isDownloaded = true
        isDownloading = false
        canResumeDownload = false
        downloadProgress = 1
        currentEstimatedBytes = cachedDirectory.1
        currentDownloadedBytes = currentEstimatedBytes
        error = nil
        resetETA()
        persistState(modelPath: cachedDirectory.0.location.path)
    }

    private func finishFailedDownload(_ error: Error) {
        let message = describe(error)
        stopProgressMonitor()
        self.error = message
        isDownloading = false
        canResumeDownload = false
        resetETA()
        AppDiagnostics.shared.record(
            "MLX model bundle download failed",
            category: "download",
            metadata: ["error": message]
        )
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
        estimatedSecondsRemaining = nil
        currentDownloadSpeedBytesPerSecond = nil
        lastSpeedSampleDate = nil
        lastSpeedSampleBytes = currentDownloadedBytes
    }

    private func startETA() {
        estimatedSecondsRemaining = nil
        currentDownloadSpeedBytesPerSecond = nil
        lastSpeedSampleDate = Date()
        lastSpeedSampleBytes = currentDownloadedBytes
    }

    private func startProgressMonitor() {
        stopProgressMonitor()
        let hub = hubClient()

        progressMonitorTask = Task { [weak self, hub] in
            while !Task.isCancelled {
                let snapshot = await BackgroundModelDownloadCoordinator.shared.snapshot(using: hub)
                guard !Task.isCancelled else {
                    return
                }

                guard let self else {
                    return
                }

                await self.refreshFromBackgroundSnapshot(snapshot)
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func stopProgressMonitor() {
        progressMonitorTask?.cancel()
        progressMonitorTask = nil
    }

    private func firstValidModelDirectoryAsync(using hub: HubApi) async -> (ValidatedModelDirectory, Int64)? {
        await Task.detached(priority: .utility) {
            for repositoryID in knownModelRepositoryIDs {
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
        knownModelRepositoryIDs.map { hub.localRepoLocation(Hub.Repo(id: $0)) }
    }

    private func purgeStaleDownloadDirectories(
        using hub: HubApi,
        preservePrimaryRepository: Bool
    ) async {
        let directories = allKnownModelDirectories(using: hub)
        let preservedLocation = preservePrimaryRepository
            ? hub.localRepoLocation(Hub.Repo(id: Gemma4MLXSupport.repositoryID))
            : nil

        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default

            for cachedDirectory in directories where fileManager.fileExists(atPath: cachedDirectory.path) {
                if let preservedLocation, cachedDirectory == preservedLocation {
                    continue
                }
                try? fileManager.removeItem(at: cachedDirectory)
            }
        }.value
    }

    private func applyMissingValidatedModelState(_ snapshot: BackgroundModelDownloadSnapshot) {
        modelPath = nil
        isDownloaded = false
        clearPersistedState()
        applyBackgroundSnapshot(snapshot)

        if snapshot.totalBytes > 0,
            snapshot.completedBytes >= snapshot.totalBytes,
            !snapshot.hasPendingWork,
            !snapshot.hasRunningTasks,
            error == nil
        {
            error = "The downloaded model bundle was incomplete or invalid. Try setup again."
        }
    }

    private func applyBackgroundSnapshot(_ snapshot: BackgroundModelDownloadSnapshot) {
        isDownloading = snapshot.hasRunningTasks
        canResumeDownload = snapshot.hasPendingWork && !snapshot.hasRunningTasks
        currentDownloadedBytes = snapshot.completedBytes
        currentEstimatedBytes = max(snapshot.totalBytes, Gemma4MLXSupport.approximateDownloadBytes)
        downloadProgress = snapshot.progress
        error = snapshot.hasRunningTasks ? nil : snapshot.lastError
        updateSpeedSample(with: snapshot.completedBytes, running: snapshot.hasRunningTasks)
        updateETA()
    }

    private func updateSpeedSample(with completedBytes: Int64, running: Bool) {
        guard running else {
            currentDownloadSpeedBytesPerSecond = nil
            lastSpeedSampleDate = Date()
            lastSpeedSampleBytes = completedBytes
            return
        }

        let now = Date()
        guard let lastSpeedSampleDate else {
            self.lastSpeedSampleDate = now
            lastSpeedSampleBytes = completedBytes
            currentDownloadSpeedBytesPerSecond = nil
            return
        }

        let elapsed = now.timeIntervalSince(lastSpeedSampleDate)
        guard elapsed > 0 else {
            return
        }

        let deltaBytes = max(completedBytes - lastSpeedSampleBytes, 0)
        currentDownloadSpeedBytesPerSecond = deltaBytes > 0 ? Double(deltaBytes) / elapsed : nil
        self.lastSpeedSampleDate = now
        lastSpeedSampleBytes = completedBytes
    }

    private func refreshFromBackgroundSnapshot(_ snapshot: BackgroundModelDownloadSnapshot) async {
        applyBackgroundSnapshot(snapshot)

        if snapshot.totalBytes > 0,
            snapshot.completedBytes >= snapshot.totalBytes,
            !snapshot.hasPendingWork,
            !snapshot.hasRunningTasks
        {
            await validateDownloadedModel()
            if isDownloaded {
                stopProgressMonitor()
            }
            return
        }

        if !snapshot.hasRunningTasks {
            stopProgressMonitor()
        }
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
        canResumeDownload = false
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
