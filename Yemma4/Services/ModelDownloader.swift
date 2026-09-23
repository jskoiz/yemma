import Foundation
import Observation
@preconcurrency import Hub

enum SetupRecoveryAction {
    case resumeDownload
    case retryDownload
    case retryModelDeletion
    case retryModelLoad

    var title: String {
        switch self {
        case .resumeDownload:
            return "Resume download"
        case .retryDownload:
            return "Retry download"
        case .retryModelDeletion:
            return "Retry removal"
        case .retryModelLoad:
            return "Retry model load"
        }
    }
}

@MainActor
struct AppSetupSnapshot {
    enum OnboardingPhase: String {
        case simulator
        case appleReady
        case appleUnavailable
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
            case .appleReady:
                return "sparkles"
            case .appleUnavailable:
                return "exclamationmark.triangle.fill"
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
    let selectedRuntime: InferenceRuntime
    let appleFoundationModelAvailability: AppleFoundationModelAvailability
    let isDownloaded: Bool
    let isDownloading: Bool
    let isValidatingDownloadedModel: Bool
    let isDeletingModel: Bool
    let modelDeletionError: String?
    let canResumeDownload: Bool
    let downloadError: String?
    let downloadProgress: Double
    let estimatedDownloadBytes: Int64
    let downloadedBytes: Int64
    let remainingDownloadBytes: Int64
    let estimatedSecondsRemaining: Double?
    let currentDownloadSpeedBytesPerSecond: Double?
    let requiredFreeSpaceBytes: Int64
    let lastValidationDate: Date?
    let allowsCellularDownload: Bool
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
        selectedRuntime = llmService.selectedRuntime
        appleFoundationModelAvailability = llmService.appleFoundationModelAvailability
        isDownloaded = modelDownloader.isDownloaded
        isDownloading = modelDownloader.isDownloading
        isValidatingDownloadedModel = modelDownloader.isValidatingDownloadedModel
        isDeletingModel = modelDownloader.isDeletingModel
        modelDeletionError = modelDownloader.modelDeletionError
        canResumeDownload = modelDownloader.canResumeDownload
        downloadError = modelDownloader.error
        downloadProgress = modelDownloader.downloadProgress
        estimatedDownloadBytes = modelDownloader.estimatedDownloadBytes
        downloadedBytes = modelDownloader.downloadedBytes
        remainingDownloadBytes = modelDownloader.remainingDownloadBytes
        estimatedSecondsRemaining = modelDownloader.estimatedSecondsRemaining
        currentDownloadSpeedBytesPerSecond = modelDownloader.currentDownloadSpeedBytesPerSecond
        requiredFreeSpaceBytes = modelDownloader.requiredFreeSpaceBytes
        lastValidationDate = modelDownloader.lastValidationDate
        allowsCellularDownload = modelDownloader.allowsCellularDownload
        isTextModelReady = llmService.isTextModelReady
        isModelLoading = llmService.isModelLoading
        modelLoadStage = llmService.modelLoadStage
        modelLoadError = llmService.lastError
    }

    var canOpenChatShell: Bool {
        guard supportsLocalModelRuntime else { return false }

        switch selectedRuntime {
        case .appleFoundationModel:
            return isTextModelReady
        case .qwen35:
            return isDownloaded || isModelLoading || isTextModelReady
        }
    }

    var hasModelPreparationError: Bool {
        supportsLocalModelRuntime
            && selectedRuntime == .qwen35
            && isDownloaded
            && !isTextModelReady
            && !isModelLoading
            && modelLoadError != nil
    }

    var visibleErrorMessage: String? {
        if selectedRuntime == .appleFoundationModel,
           !appleFoundationModelAvailability.isAvailable {
            return appleFoundationModelAvailability.detail
        }

        if hasModelPreparationError {
            return modelLoadError
        }

        if let modelDeletionError {
            return modelDeletionError
        }

        return downloadError
    }

    func onboardingPhase(isStartingDownload: Bool = false) -> OnboardingPhase {
        if !supportsLocalModelRuntime {
            return .simulator
        }

        if selectedRuntime == .appleFoundationModel {
            return appleFoundationModelAvailability.isAvailable ? .appleReady : .appleUnavailable
        }

        if isValidatingDownloadedModel {
            return .preparing
        }

        if isDeletingModel {
            return .preparing
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

        if selectedRuntime == .appleFoundationModel {
            return appleFoundationModelAvailability.title
        }

        if isValidatingDownloadedModel {
            return "Checking your saved model."
        }

        if isDeletingModel {
            return "Removing the downloaded model."
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

        if selectedRuntime == .appleFoundationModel {
            return appleFoundationModelAvailability.isAvailable
                ? "The built-in model runs locally without a Yemma model download."
                : appleFoundationModelAvailability.detail
        }

        if isValidatingDownloadedModel {
            return "Confirming the local files are complete before Yemma uses them."
        }

        if isDeletingModel {
            return "Removing the optional Qwen files from this iPhone."
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
        guard supportsLocalModelRuntime, selectedRuntime == .qwen35, isDownloading else {
            return nil
        }
        return downloadProgress
    }

    var isShowingChatFailure: Bool {
        guard supportsLocalModelRuntime else { return false }

        if selectedRuntime == .appleFoundationModel {
            return !appleFoundationModelAvailability.isAvailable
        }

        return downloadError != nil || hasModelPreparationError
    }

    var chatRecoveryAction: SetupRecoveryAction? {
        guard supportsLocalModelRuntime,
              selectedRuntime == .qwen35,
              !isDownloading,
              !isValidatingDownloadedModel,
              !isDeletingModel else {
            return nil
        }

        if modelDeletionError != nil {
            return .retryModelDeletion
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
            && selectedRuntime == .qwen35
            && !isTextModelReady
            && modelLoadError == nil
            && (isDownloaded || isValidatingDownloadedModel || isDeletingModel)
    }

    var preparationStatusText: String {
        if isValidatingDownloadedModel {
            return "Checking your saved model."
        }
        if isDeletingModel {
            return "Removing the downloaded model."
        }
        return modelLoadStage.statusText
    }

    static func formatETA(_ seconds: Double) -> String {
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
    public var downloadProgress: Double = 0
    public var isDownloading: Bool = false
    public var isDownloaded: Bool = false
    public private(set) var isValidatingDownloadedModel: Bool = false
    public private(set) var isDeletingModel: Bool = false
    public private(set) var modelDeletionError: String?
    public var canResumeDownload: Bool = false
    public var error: String?
    public var modelPath: String?
    public var estimatedSecondsRemaining: Double?
    public var currentDownloadSpeedBytesPerSecond: Double?
    public var allowsCellularDownload: Bool {
        didSet {
            defaults.set(allowsCellularDownload, forKey: Self.allowsCellularDownloadKey)
        }
    }
    public private(set) var lastValidationDate: Date?
    private var lastSpeedSampleDate: Date?
    private var lastSpeedSampleBytes: Int64 = 0
    private var currentDownloadedBytes: Int64 = 0
    private var currentEstimatedBytes: Int64 = Qwen35MLXSupport.approximateDownloadBytes

    private static let legacyRepositoryID = "mlx-community/gemma-4-e2b-it-4bit"
    public private(set) var hasLegacyModelFiles = false

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let makeHub: @Sendable () -> HubApi
    @ObservationIgnored private var cachedHub: HubApi?
    @ObservationIgnored private var progressMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var activeValidationID: UUID?
    @ObservationIgnored private var deletionTask: Task<Bool, Never>?
    @ObservationIgnored private var activeDeletionID: UUID?
    @ObservationIgnored private var modelLifecycleRevision: UInt64 = 0
    @ObservationIgnored private var isModelDeletionPending = false

    static let persistedModelPathKey = "com.avmillabs.yemma4.modelDownloader.modelPath"
    static let modelDeletionPendingKey = "com.avmillabs.yemma4.modelDownloader.deletionPending"
    static let allowsCellularDownloadKey = "com.avmillabs.yemma4.modelDownloader.allowsCellularDownload"
    static let lastValidationDateKey = "com.avmillabs.yemma4.modelDownloader.lastValidationDate"

    public init(
        fileManager: FileManager = .default,
        hubFactory: @escaping @Sendable () -> HubApi = { .shared },
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.makeHub = hubFactory
        allowsCellularDownload = defaults.object(forKey: Self.allowsCellularDownloadKey) as? Bool ?? false
        lastValidationDate = defaults.object(forKey: Self.lastValidationDateKey) as? Date
        hasLegacyModelFiles = fileManager.fileExists(atPath: hubClient().localRepoLocation(
            Hub.Repo(id: Self.legacyRepositoryID)
        ).path)
        restorePersistedState()
    }

    public var estimatedDownloadBytes: Int64 {
        max(currentEstimatedBytes, currentDownloadedBytes)
    }

    public var requiredFreeSpaceBytes: Int64 {
        ModelDownloadStorageCheck.requiredBytes(forModelBytes: estimatedDownloadBytes)
    }

    public var downloadedBytes: Int64 {
        currentDownloadedBytes
    }

    public var remainingDownloadBytes: Int64 {
        max(estimatedDownloadBytes - currentDownloadedBytes, 0)
    }

    public var activeDownloadLabel: String {
        if isDownloaded {
            return "Shipped model bundle is ready"
        }

        if isDownloading {
            return "Downloading shipped model"
        }

        if canResumeDownload {
            return "Ready to resume setup"
        }

        return "Waiting to download"
    }

    public var activeDownloadDetail: String {
        if isDownloaded {
            return "Everything is saved on this iPhone for the shipped model."
        }

        if isDownloading {
            return "Downloading the shipped model from Hugging Face."
        }

        if canResumeDownload {
            return "Resume the saved setup progress."
        }

        return "Yemma needs a one-time local model download before chat is ready."
    }

    public func validateDownloadedModel() async {
        if let validationTask {
            await validationTask.value
            return
        }

        if let deletionTask {
            _ = await deletionTask.value
            return
        }

        guard !isModelDeletionPending else {
            applyPendingModelDeletionState()
            return
        }

        let validationID = UUID()
        let validationRevision = modelLifecycleRevision
        let hub = hubClient()
        isValidatingDownloadedModel = true
        activeValidationID = validationID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDownloadedModelValidation(
                using: hub,
                revision: validationRevision
            )
        }
        validationTask = task

        await task.value
        guard activeValidationID == validationID else { return }

        validationTask = nil
        activeValidationID = nil
        isValidatingDownloadedModel = false
        markValidationCompleted()
    }

    private func performDownloadedModelValidation(
        using hub: HubApi,
        revision: UInt64
    ) async {
        guard Yemma4AppConfiguration.supportsLocalModelRuntime else {
            guard revision == modelLifecycleRevision else { return }
            resetForUnsupportedRuntime()
            AppDiagnostics.shared.record(
                "Skipped local MLX model validation on unsupported runtime",
                category: "download"
            )
            return
        }

        let validation = await firstValidModelDirectoryAsync(using: hub)
        guard revision == modelLifecycleRevision else { return }

        if let validation {
            await BackgroundModelDownloadCoordinator.shared.clearTransientState(
                using: hub,
                repositoryID: Qwen35MLXSupport.repositoryID
            )
            guard revision == modelLifecycleRevision else { return }
            finishWithCachedDownload(validation)
        } else {
            let snapshot = await BackgroundModelDownloadCoordinator.shared.snapshot(
                using: hub,
                repositoryID: Qwen35MLXSupport.repositoryID
            )
            guard revision == modelLifecycleRevision else { return }
            applyMissingValidatedModelState(snapshot)
        }

        AppDiagnostics.shared.record(
            "Validated local MLX model state",
            category: "download",
            metadata: [
                "repository": Qwen35MLXSupport.repositoryID,
                "isDownloaded": isDownloaded,
                "modelPath": modelPath ?? "nil"
            ]
        )
    }

    public func downloadModel() async {
        if let deletionTask {
            _ = await deletionTask.value
            return
        }

        guard !isModelDeletionPending else {
            applyPendingModelDeletionState()
            return
        }

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
                await BackgroundModelDownloadCoordinator.shared.clearTransientState(
                    using: hub,
                    repositoryID: Qwen35MLXSupport.repositoryID
                )
                return
            }

            prepareForDownload()

            AppDiagnostics.shared.record(
                "Starting MLX model bundle download",
                category: "download",
                metadata: ["repository": Qwen35MLXSupport.repositoryID]
            )

            let snapshot = try await BackgroundModelDownloadCoordinator.shared.startDownload(
                using: hub,
                repositoryID: Qwen35MLXSupport.repositoryID,
                revision: Qwen35MLXSupport.repositoryRevision,
                matching: Qwen35MLXSupport.downloadPatterns,
                allowsCellularDownload: allowsCellularDownload
            )

            applyBackgroundSnapshot(snapshot)
            if snapshot.hasRunningTasks {
                startProgressMonitor()
            }
        } catch {
            finishFailedDownload(error)
            let snapshot = await BackgroundModelDownloadCoordinator.shared.snapshot(
                using: hub,
                repositoryID: Qwen35MLXSupport.repositoryID
            )
            if snapshot.lastError != nil || snapshot.hasPendingWork || snapshot.hasRunningTasks {
                applyBackgroundSnapshot(snapshot)
            }
        }
    }

    /// Pauses active URLSession tasks and preserves resumable data. This does
    /// not delete verified files that have already completed.
    public func pauseDownload() async {
        guard isDownloading else { return }
        stopProgressMonitor()
        let hub = hubClient()
        let snapshot = await BackgroundModelDownloadCoordinator.shared.pauseDownload(
            using: hub,
            repositoryID: Qwen35MLXSupport.repositoryID
        )
        applyBackgroundSnapshot(snapshot)
        AppDiagnostics.shared.record("Paused MLX model download", category: "download")
    }

    /// Cancels active tasks and removes resume blobs while retaining verified
    /// completed files for a later user-initiated restart.
    public func cancelDownload() async {
        guard isDownloading || canResumeDownload else { return }
        stopProgressMonitor()
        let hub = hubClient()
        let snapshot = await BackgroundModelDownloadCoordinator.shared.cancelDownload(
            using: hub,
            repositoryID: Qwen35MLXSupport.repositoryID
        )
        applyBackgroundSnapshot(snapshot)
        AppDiagnostics.shared.record("Canceled MLX model download", category: "download")
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

    @discardableResult
    public func deleteModel() async -> Bool {
        if let deletionTask {
            return await deletionTask.value
        }

        let hub = hubClient()
        stopProgressMonitor()
        let validationToDrain = invalidateValidation()
        unpublishModelForDeletion()

        let deletionID = UUID()
        activeDeletionID = deletionID
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let didDelete = await self.performModelDeletion(
                using: hub,
                after: validationToDrain
            )
            self.isDeletingModel = false
            return didDelete
        }
        deletionTask = task

        let didDelete = await task.value
        guard activeDeletionID == deletionID else { return didDelete }

        deletionTask = nil
        activeDeletionID = nil
        return didDelete
    }

    private func performModelDeletion(
        using hub: HubApi,
        after validationTask: Task<Void, Never>?
    ) async -> Bool {
        await validationTask?.value

        await BackgroundModelDownloadCoordinator.shared.clearState(
            using: hub,
            repositoryID: Qwen35MLXSupport.repositoryID
        )

        await BackgroundModelDownloadCoordinator.shared.clearState(using: hub, repositoryID: Self.legacyRepositoryID)
        let cachedDirectories = [Qwen35MLXSupport.repositoryID, Self.legacyRepositoryID].map {
            hub.localRepoLocation(Hub.Repo(id: $0))
        }
        let fileManager = self.fileManager

        do {
            try await Task.detached(priority: .utility) {
                for directory in cachedDirectories where fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
            }.value

            hasLegacyModelFiles = false
            clearModelDeletionTombstone()
            AppDiagnostics.shared.record("Deleted local MLX model bundle", category: "download")
            return true
        } catch {
            let message = describe(error)
            self.error = message
            modelDeletionError = message
            AppDiagnostics.shared.record(
                "MLX model delete failed",
                category: "download",
                metadata: ["error": message]
            )
            return false
        }
    }

    private func unpublishModelForDeletion() {
        isModelDeletionPending = true
        defaults.set(true, forKey: Self.modelDeletionPendingKey)
        isDeletingModel = true
        modelPath = nil
        isDownloaded = false
        isDownloading = false
        canResumeDownload = false
        downloadProgress = 0
        currentDownloadedBytes = 0
        currentEstimatedBytes = Qwen35MLXSupport.approximateDownloadBytes
        lastValidationDate = nil
        defaults.removeObject(forKey: Self.lastValidationDateKey)
        error = nil
        modelDeletionError = nil
        resetETA()
        persistState(modelPath: nil)
    }

    private func clearModelDeletionTombstone() {
        isModelDeletionPending = false
        defaults.removeObject(forKey: Self.modelDeletionPendingKey)
        modelDeletionError = nil
        error = nil
    }

    private func applyPendingModelDeletionState() {
        let message = modelDeletionError ?? Self.interruptedDeletionMessage
        isModelDeletionPending = true
        isDeletingModel = false
        isValidatingDownloadedModel = false
        modelPath = nil
        isDownloaded = false
        isDownloading = false
        canResumeDownload = false
        downloadProgress = 0
        currentDownloadedBytes = 0
        currentEstimatedBytes = Qwen35MLXSupport.approximateDownloadBytes
        modelDeletionError = message
        error = message
        resetETA()
        persistState(modelPath: nil)
    }

    private func invalidateValidation() -> Task<Void, Never>? {
        modelLifecycleRevision &+= 1
        let task = validationTask
        task?.cancel()
        validationTask = nil
        activeValidationID = nil
        isValidatingDownloadedModel = false
        return task
    }

    private func resetForUnsupportedRuntime() {
        stopProgressMonitor()
        isDownloading = false
        isDownloaded = false
        canResumeDownload = false
        downloadProgress = 0
        modelPath = nil
        currentDownloadedBytes = 0
        currentEstimatedBytes = Qwen35MLXSupport.approximateDownloadBytes
        estimatedSecondsRemaining = nil
        currentDownloadSpeedBytesPerSecond = nil
        lastValidationDate = nil
        defaults.removeObject(forKey: Self.lastValidationDateKey)
        error = Self.unsupportedRuntimeMessage
        modelDeletionError = nil
        persistState(modelPath: nil)
    }

    private func prepareForDownload() {
        stopProgressMonitor()
        isDownloading = true
        isDownloaded = false
        canResumeDownload = false
        error = nil
        modelDeletionError = nil
        downloadProgress = 0
        currentDownloadedBytes = 0
        currentEstimatedBytes = Qwen35MLXSupport.approximateDownloadBytes
        lastValidationDate = nil
        defaults.removeObject(forKey: Self.lastValidationDateKey)
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
        modelDeletionError = nil
        resetETA()
        markValidationCompleted()
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
                    repositoryID: Qwen35MLXSupport.repositoryID
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
        guard await BackgroundModelDownloadCoordinator.shared.verifyCachedFiles(
            using: hub,
            repositoryID: Qwen35MLXSupport.repositoryID,
            revision: Qwen35MLXSupport.repositoryRevision
        ) else {
            return nil
        }

        let validationTask = Task.detached(priority: .utility) {
            () -> (directory: ValidatedModelDirectory, size: Int64, error: String?)? in
            let location = hub.localRepoLocation(Hub.Repo(id: Qwen35MLXSupport.repositoryID))
            guard let validatedDirectory = try? ModelDirectoryValidator.validatedDirectory(at: location) else {
                return nil
            }

            // Check the processor, image-aware template, and actual vision tensor
            // headers before publishing readiness. Weight payloads stay on disk.
            do {
                try Qwen35MLXSupport.validateAssetContract(validatedDirectory)
            } catch {
                AppDiagnostics.shared.record(
                    "Rejected downloaded MLX bundle that failed the Qwen3.5 4B asset contract",
                    category: "download",
                    metadata: [
                        "repository": Qwen35MLXSupport.repositoryID,
                        "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    ]
                )
                return (
                    directory: validatedDirectory,
                    size: Qwen35MLXSupport.directorySize(at: location),
                    error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }

            return (
                directory: validatedDirectory,
                size: Qwen35MLXSupport.directorySize(at: location),
                error: nil
            )
        }

        guard let result = await validationTask.value else {
            return nil
        }

        if let error = result.error {
            BackgroundModelDownloadCoordinator.shared.invalidateCachedFiles(
                using: hub,
                repositoryID: Qwen35MLXSupport.repositoryID,
                reason: error
            )
            return nil
        }

        return (result.directory, result.size)
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
        currentEstimatedBytes = max(snapshot.totalBytes, Qwen35MLXSupport.approximateDownloadBytes)
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
                Yemma could not download the shipped Hugging Face model (\(Qwen35MLXSupport.repositoryID)) because authentication was required. Check your connection and try again.
                """
        }

        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private static let unsupportedRuntimeMessage =
        "Local MLX downloads are disabled in the iOS Simulator. Run Yemma on a physical iPhone for real on-device inference."
    private static let interruptedDeletionMessage =
        "The previous model removal did not finish. Retry removal to clear the optional Qwen files."

    private func restorePersistedState() {
        if defaults.bool(forKey: Self.modelDeletionPendingKey) {
            applyPendingModelDeletionState()
            return
        }

        guard let persistedModelPath = defaults.string(forKey: Self.persistedModelPathKey) else {
            return
        }

        guard fileManager.fileExists(atPath: persistedModelPath) else {
            persistState(modelPath: nil)
            return
        }

        isValidatingDownloadedModel = true
        canResumeDownload = false
        downloadProgress = 0
        error = nil
    }

    private func markValidationCompleted() {
        let date = Date()
        lastValidationDate = date
        defaults.set(date, forKey: Self.lastValidationDateKey)
    }

    private func persistState(modelPath: String?) {
        if let modelPath {
            defaults.set(modelPath, forKey: Self.persistedModelPathKey)
        } else {
            defaults.removeObject(forKey: Self.persistedModelPathKey)
        }
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
