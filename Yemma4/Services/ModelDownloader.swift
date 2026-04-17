import Foundation
import Observation
@preconcurrency import Hub

public struct LocalModelResources: Sendable {
    public let modelDirectoryPath: String
}

enum SetupRecoveryAction {
    case resumeDownload
    case retryDownload
    case retryModelLoad

    var title: String {
        switch self {
        case .resumeDownload:
            return "Resume download"
        case .retryDownload:
            return "Retry download"
        case .retryModelLoad:
            return "Retry model load"
        }
    }
}

@MainActor
struct AppSetupSnapshot {
    enum OnboardingPhase: String {
        case simulator
        case intro
        case downloading
        case paused
        case preparing
        case ready
        case failed

        var systemImage: String {
            switch self {
            case .simulator:
                return "desktopcomputer"
            case .intro:
                return "arrow.down.circle"
            case .downloading:
                return "arrow.down.circle.fill"
            case .paused:
                return "pause.circle.fill"
            case .preparing:
                return "bolt.circle.fill"
            case .ready:
                return "checkmark.circle.fill"
            case .failed:
                return "exclamationmark.triangle.fill"
            }
        }
    }

    let supportsLocalModelRuntime: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let canResumeDownload: Bool
    let downloadError: String?
    let downloadProgress: Double
    let estimatedDownloadBytes: Int64
    let downloadedBytes: Int64
    let remainingDownloadBytes: Int64
    let estimatedSecondsRemaining: Double?
    let currentDownloadSpeedBytesPerSecond: Double?
    let isTextModelReady: Bool
    let isModelLoading: Bool
    let modelLoadStage: ModelLoadStage
    let modelLoadError: String?

    init(
        supportsLocalModelRuntime: Bool,
        modelDownloader: ModelDownloader,
        llmService: LLMService
    ) {
        self.supportsLocalModelRuntime = supportsLocalModelRuntime
        isDownloaded = modelDownloader.isDownloaded
        isDownloading = modelDownloader.isDownloading
        canResumeDownload = modelDownloader.canResumeDownload
        downloadError = modelDownloader.error
        downloadProgress = modelDownloader.downloadProgress
        estimatedDownloadBytes = modelDownloader.estimatedDownloadBytes
        downloadedBytes = modelDownloader.downloadedBytes
        remainingDownloadBytes = modelDownloader.remainingDownloadBytes
        estimatedSecondsRemaining = modelDownloader.estimatedSecondsRemaining
        currentDownloadSpeedBytesPerSecond = modelDownloader.currentDownloadSpeedBytesPerSecond
        isTextModelReady = llmService.isTextModelReady
        isModelLoading = llmService.isModelLoading
        modelLoadStage = llmService.modelLoadStage
        modelLoadError = llmService.lastError
    }

    var canOpenChatShell: Bool {
        supportsLocalModelRuntime && (isDownloaded || isModelLoading || isTextModelReady)
    }

    var hasModelPreparationError: Bool {
        supportsLocalModelRuntime
            && isDownloaded
            && !isTextModelReady
            && !isModelLoading
            && modelLoadError != nil
    }

    var visibleErrorMessage: String? {
        if hasModelPreparationError {
            return modelLoadError
        }

        return downloadError
    }

    func onboardingPhase(isStartingDownload: Bool = false) -> OnboardingPhase {
        if !supportsLocalModelRuntime {
            return .simulator
        }

        if hasModelPreparationError || downloadError != nil {
            return .failed
        }

        if isDownloaded {
            return isTextModelReady ? .ready : .preparing
        }

        if canResumeDownload {
            return .paused
        }

        if isDownloading || isStartingDownload {
            return .downloading
        }

        return .intro
    }

    var chatStatusText: String {
        if !supportsLocalModelRuntime {
            return "Simulator mode with mock replies."
        }

        if isDownloading {
            return "Downloading your on-device model."
        }

        if canResumeDownload {
            return "Setup paused before Yemma finished downloading."
        }

        if downloadError != nil {
            return "Yemma needs help finishing setup."
        }

        if isModelLoading {
            return modelLoadStage.statusText
        }

        if hasModelPreparationError {
            return "Yemma could not finish getting ready."
        }

        return "Getting Yemma ready."
    }

    var chatStatusDetailText: String? {
        if !supportsLocalModelRuntime {
            return nil
        }

        if isDownloading {
            let percent = Int(downloadProgress * 100)
            if let estimatedSecondsRemaining {
                return "\(percent)% downloaded. \(Self.formatETA(estimatedSecondsRemaining)) remaining."
            }
            return "\(percent)% downloaded. Yemma can keep downloading in the background."
        }

        if let downloadError {
            return downloadError
        }

        if canResumeDownload {
            return "Resume setup to finish preparing Yemma on this device."
        }

        if hasModelPreparationError {
            return modelLoadError
        }

        if isModelLoading {
            return "Almost there. Yemma is waking up now."
        }

        return nil
    }

    var chatStatusProgress: Double? {
        guard supportsLocalModelRuntime, isDownloading else { return nil }
        return downloadProgress
    }

    var isShowingChatFailure: Bool {
        supportsLocalModelRuntime && (downloadError != nil || hasModelPreparationError)
    }

    var chatRecoveryAction: SetupRecoveryAction? {
        guard supportsLocalModelRuntime, !isDownloading else {
            return nil
        }

        if canResumeDownload {
            return .resumeDownload
        }

        if downloadError != nil {
            return .retryDownload
        }

        if hasModelPreparationError {
            return .retryModelLoad
        }

        return nil
    }

    var shouldShowStartupOverlay: Bool {
        supportsLocalModelRuntime
            && isDownloaded
            && !isTextModelReady
            && modelLoadError == nil
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = max(Int(seconds), 0)
        if s < 60 {
            return "less than a minute"
        }

        if s < 3600 {
            return "\(s / 60) min"
        }

        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }
}

@MainActor
@Observable
public final class ModelDownloader {
    private struct PersistedState: Codable {
        let modelSource: Gemma4ModelSource
        let modelPath: String?
    }

    public var downloadProgress: Double = 0
    public var isDownloading: Bool = false
    public var isDownloaded: Bool = false
    public var canResumeDownload: Bool = false
    public var error: String?
    public var modelPath: String?
    public var estimatedSecondsRemaining: Double?
    public var currentDownloadSpeedBytesPerSecond: Double?
    var activeModelSource: Gemma4ModelSource = Gemma4MLXSupport.defaultModelSource

    var isUsingDefaultModelSource: Bool {
        activeModelSource == Gemma4MLXSupport.defaultModelSource
    }

    var activeModelSourceBoundaryLabel: String {
        if isUsingDefaultModelSource {
            return "Shipped default"
        }

        if activeModelSource.isCustom {
            return "Custom debug source"
        }

        return "Experimental preset"
    }

    private var lastSpeedSampleDate: Date?
    private var lastSpeedSampleBytes: Int64 = 0
    private var currentDownloadedBytes: Int64 = 0
    private var currentEstimatedBytes: Int64 = Gemma4MLXSupport.defaultModelSource.approximateDownloadBytes

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let makeHub: @Sendable () -> HubApi
    @ObservationIgnored private var cachedHub: HubApi?
    @ObservationIgnored private var progressMonitorTask: Task<Void, Never>?

    private static let persistedStateKey = "com.avmillabs.yemma4.modelDownloader.state"

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
            return isUsingDefaultModelSource ? "Shipped model bundle is ready" : "Experimental model bundle is ready"
        }

        if isDownloading {
            return "Downloading \(activeModelSourceBoundaryLabel.lowercased())"
        }

        if canResumeDownload {
            return isUsingDefaultModelSource ? "Ready to resume setup" : "Ready to resume debug setup"
        }

        return isUsingDefaultModelSource ? "Waiting to download" : "Waiting to download experimental source"
    }

    public var activeDownloadDetail: String {
        if isDownloaded {
            return isUsingDefaultModelSource
                ? "Everything is saved on this iPhone for the shipped default source."
                : "Everything is saved on this iPhone for this debug-only source."
        }

        if isDownloading {
            return isUsingDefaultModelSource
                ? "Downloading the shipped default source from Hugging Face."
                : "Downloading a debug-only source from Hugging Face."
        }

        if canResumeDownload {
            return isUsingDefaultModelSource
                ? "Resume the saved setup progress."
                : "Resume the saved debug setup progress."
        }

        return isUsingDefaultModelSource
            ? "Yemma needs a one-time local model download before chat is ready."
            : "Yemma needs a one-time local download before this experimental source is ready."
    }

    func selectModelSource(_ source: Gemma4ModelSource) async {
        guard activeModelSource != source else {
            await validateDownloadedModel()
            return
        }

        let previousSource = activeModelSource
        stopProgressMonitor()
        activeModelSource = source
        modelPath = nil
        isDownloaded = false
        isDownloading = false
        canResumeDownload = false
        downloadProgress = 0
        currentDownloadedBytes = 0
        currentEstimatedBytes = source.approximateDownloadBytes
        error = nil
        resetETA()
        persistState(modelPath: nil)

        let hub = hubClient()
        await BackgroundModelDownloadCoordinator.shared.clearState(
            using: hub,
            repositoryID: previousSource.repositoryID
        )
        await validateDownloadedModel()

        AppDiagnostics.shared.record(
            "Model source selected for debug flow",
            category: "download",
            metadata: [
                "repository": source.repositoryID,
                "kind": source.kind.rawValue,
                "boundary": source == Gemma4MLXSupport.defaultModelSource ? "default" : "experimental"
            ]
        )
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
            await BackgroundModelDownloadCoordinator.shared.clearState(
                using: hub,
                repositoryID: activeModelSource.repositoryID
            )
        } else {
            let snapshot = await BackgroundModelDownloadCoordinator.shared.snapshot(
                using: hub,
                repositoryID: activeModelSource.repositoryID
            )
            applyMissingValidatedModelState(snapshot)
        }

        AppDiagnostics.shared.record(
            "Validated local MLX model state",
            category: "download",
            metadata: [
                "repository": activeModelSource.repositoryID,
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
                await BackgroundModelDownloadCoordinator.shared.clearState(
                    using: hub,
                    repositoryID: activeModelSource.repositoryID
                )
                return
            }

            await purgeStaleDownloadDirectories(
                using: hub,
                repositoryIDs: Gemma4MLXSupport.legacyRepositoryIDs(for: activeModelSource)
            )
            prepareForDownload()

            AppDiagnostics.shared.record(
                "Starting MLX model bundle download",
                category: "download",
                metadata: ["repository": activeModelSource.repositoryID]
            )

            let snapshot = try await BackgroundModelDownloadCoordinator.shared.startDownload(
                using: hub,
                repositoryID: activeModelSource.repositoryID,
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
        let source = activeModelSource
        stopProgressMonitor()

        Task { @MainActor [weak self] in
            guard let self else { return }

            await BackgroundModelDownloadCoordinator.shared.clearState(
                using: hub,
                repositoryID: source.repositoryID
            )

            let cachedDirectories = self.allKnownModelDirectories(using: hub, source: source)

            do {
                for cachedDirectory in cachedDirectories where self.fileManager.fileExists(atPath: cachedDirectory.path) {
                    try self.fileManager.removeItem(at: cachedDirectory)
                }

                self.modelPath = nil
                self.isDownloaded = false
                self.isDownloading = false
                self.canResumeDownload = false
                self.downloadProgress = 0
                self.currentDownloadedBytes = 0
                self.currentEstimatedBytes = source.approximateDownloadBytes
                self.error = nil
                self.resetETA()
                self.persistState(modelPath: nil)
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
        currentEstimatedBytes = activeModelSource.approximateDownloadBytes
        estimatedSecondsRemaining = nil
        currentDownloadSpeedBytesPerSecond = nil
        error = Self.unsupportedRuntimeMessage
        persistState(modelPath: nil)
    }

    private func prepareForDownload() {
        stopProgressMonitor()
        isDownloading = true
        isDownloaded = false
        canResumeDownload = false
        error = nil
        downloadProgress = 0
        currentDownloadedBytes = 0
        currentEstimatedBytes = activeModelSource.approximateDownloadBytes
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
                guard let self else {
                    return
                }

                let snapshot = await BackgroundModelDownloadCoordinator.shared.snapshot(
                    using: hub,
                    repositoryID: await MainActor.run { self.activeModelSource.repositoryID }
                )
                guard !Task.isCancelled else {
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
        let repositoryIDs = Gemma4MLXSupport.knownRepositoryIDs(for: activeModelSource)
        let validationTask = Task.detached(priority: .utility) { () -> (ValidatedModelDirectory, Int64)? in
            for repositoryID in repositoryIDs {
                let location = hub.localRepoLocation(Hub.Repo(id: repositoryID))
                guard let validatedDirectory = try? ModelDirectoryValidator.validatedDirectory(at: location) else {
                    continue
                }
                return (validatedDirectory, Gemma4MLXSupport.directorySize(at: location))
            }

            return nil
        }

        return await validationTask.value
    }

    private func allKnownModelDirectories(using hub: HubApi, source: Gemma4ModelSource? = nil) -> [URL] {
        Gemma4MLXSupport.knownRepositoryIDs(for: source ?? activeModelSource)
            .map { hub.localRepoLocation(Hub.Repo(id: $0)) }
    }

    private func purgeStaleDownloadDirectories(
        using hub: HubApi,
        repositoryIDs: [String]
    ) async {
        let directories = repositoryIDs.map { hub.localRepoLocation(Hub.Repo(id: $0)) }

        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default

            for cachedDirectory in directories where fileManager.fileExists(atPath: cachedDirectory.path) {
                try? fileManager.removeItem(at: cachedDirectory)
            }
        }.value
    }

    private func applyMissingValidatedModelState(_ snapshot: BackgroundModelDownloadSnapshot) {
        modelPath = nil
        isDownloaded = false
        persistState(modelPath: nil)
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
        currentEstimatedBytes = max(snapshot.totalBytes, activeModelSource.approximateDownloadBytes)
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
                Yemma could not download the configured Hugging Face model source (\(activeModelSource.repositoryID)) because authentication was required. Provide a valid Hugging Face token or switch back to the shipped default source for first-launch setup.
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
        guard let persistedData = defaults.data(forKey: Self.persistedStateKey) else {
            return
        }

        guard let persistedState = try? JSONDecoder().decode(PersistedState.self, from: persistedData) else {
            defaults.removeObject(forKey: Self.persistedStateKey)
            return
        }

        activeModelSource = persistedState.modelSource
        currentEstimatedBytes = activeModelSource.approximateDownloadBytes

        guard let persistedModelPath = persistedState.modelPath else {
            return
        }

        guard fileManager.fileExists(atPath: persistedModelPath) else {
            persistState(modelPath: nil)
            return
        }

        modelPath = persistedModelPath
        isDownloaded = true
        canResumeDownload = false
        downloadProgress = 1
        error = nil
        let size = Gemma4MLXSupport.directorySize(at: URL(fileURLWithPath: persistedModelPath))
        currentEstimatedBytes = max(size, activeModelSource.approximateDownloadBytes)
        currentDownloadedBytes = currentEstimatedBytes
    }

    private func persistState(modelPath: String?) {
        let state = PersistedState(modelSource: activeModelSource, modelPath: modelPath)
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: Self.persistedStateKey)
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
