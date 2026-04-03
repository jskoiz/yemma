import Foundation
import Observation

@MainActor
@Observable
public final class ModelDownloader {
    public var downloadProgress: Double = 0
    public var isDownloading: Bool = false
    public var isDownloaded: Bool = false
    public var error: String?
    public var modelPath: String?

    private let modelDownloadURL = URL(string: "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF/resolve/main/google_gemma-4-E4B-it-Q4_K_M.gguf")!
    private let modelFileName = "gemma-4-e4b-it-q4km.gguf"
    private let resumeDataFileName = "gemma-4-e4b-it-q4km.resume-data"
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validateDownloadedModel() async {
        let fileManager = self.fileManager
        let modelFileURL = self.modelFileURL
        let resumeDataURL = self.resumeDataURL

        let result = await Task.detached(priority: .utility) {
            ModelDownloaderIO.validateLocalModel(
                fileManager: fileManager,
                modelFileURL: modelFileURL,
                resumeDataURL: resumeDataURL
            )
        }.value

        isDownloaded = result.isDownloaded
        modelPath = result.modelPath
        if !isDownloading {
            downloadProgress = result.isDownloaded ? max(downloadProgress, 1) : 0
        }
    }

    public func downloadModel() async {
        guard !isDownloading else { return }

        await validateDownloadedModel()
        error = nil

        if isDownloaded, let modelPath {
            downloadProgress = 1
            self.modelPath = modelPath
            return
        }

        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        do {
            let fileManager = self.fileManager
            let destinationURL = modelFileURL
            let resumeDataURL = self.resumeDataURL
            let resumeData = await Task.detached(priority: .utility) {
                ModelDownloaderIO.loadResumeDataIfAvailable(fileManager: fileManager, resumeDataURL: resumeDataURL)
            }.value

            let downloadResult = try await ModelDownloadCoordinator(
                downloadURL: modelDownloadURL,
                resumeData: resumeData,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = progress
                    }
                }
            ).download()

            try await Task.detached(priority: .utility) {
                try ModelDownloaderIO.persistDownloadedFile(
                    fileManager: fileManager,
                    from: downloadResult.stagedFileURL,
                    to: destinationURL
                )
                ModelDownloaderIO.clearResumeData(fileManager: fileManager, resumeDataURL: resumeDataURL)
            }.value

            downloadProgress = 1
            isDownloaded = true
            modelPath = destinationURL.path
            error = nil
        } catch {
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                let resumeDataURL = self.resumeDataURL
                await Task.detached(priority: .utility) {
                    try? resumeData.write(to: resumeDataURL, options: [.atomic])
                }.value
            }
            self.error = Self.describe(error)
            await validateDownloadedModel()
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
        } else {
            error = nil
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
            default:
                break
            }
        }

        if let localizedDescription = nsError.localizedFailureReason, !localizedDescription.isEmpty {
            return localizedDescription
        }

        return nsError.localizedDescription
    }
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
            clearInvalidLocalState(fileManager: fileManager, modelFileURL: modelFileURL, resumeDataURL: resumeDataURL)
            return ValidationResult(isDownloaded: false, modelPath: nil)
        }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: modelFileURL.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0
        else {
            clearInvalidLocalState(fileManager: fileManager, modelFileURL: modelFileURL, resumeDataURL: resumeDataURL)
            return ValidationResult(isDownloaded: false, modelPath: nil)
        }

        return ValidationResult(isDownloaded: true, modelPath: modelFileURL.path)
    }

    static func clearInvalidLocalState(fileManager: FileManager, modelFileURL: URL, resumeDataURL: URL) {
        if fileManager.fileExists(atPath: modelFileURL.path) {
            try? fileManager.removeItem(at: modelFileURL)
        }

        if fileManager.fileExists(atPath: resumeDataURL.path) {
            try? fileManager.removeItem(at: resumeDataURL)
        }
    }

    static func persistDownloadedFile(fileManager: FileManager, from tempURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }
}

private final class ModelDownloadCoordinator: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    struct Result {
        let stagedFileURL: URL
    }

    private let downloadURL: URL
    private let resumeData: Data?
    private let progressHandler: @Sendable (Double) -> Void
    private let fileManager = FileManager.default

    private var session: URLSession?
    private var continuation: CheckedContinuation<Result, Error>?
    private var lastReportedProgress: Double = 0
    private var lastProgressUpdate = Date.distantPast

    init(downloadURL: URL, resumeData: Data?, progressHandler: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.downloadURL = downloadURL
        self.resumeData = resumeData
        self.progressHandler = progressHandler
    }

    func download() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.session = makeSession()

            let task: URLSessionDownloadTask
            if let resumeData {
                task = session!.downloadTask(withResumeData: resumeData)
            } else {
                task = session!.downloadTask(with: downloadURL)
            }

            task.resume()
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        let now = Date()
        let progressDelta = progress - lastReportedProgress
        let shouldReport = progress >= 1
            || progressDelta >= 0.005
            || now.timeIntervalSince(lastProgressUpdate) >= 0.15

        guard shouldReport else { return }

        lastReportedProgress = progress
        lastProgressUpdate = now

        Task { @MainActor in
            self.progressHandler(progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            finish()
            return
        }

        // Download tasks deliver the temporary file URL via didFinishDownloadingTo.
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let stagedURL = try makeStagedDownloadURL()

            if fileManager.fileExists(atPath: stagedURL.path) {
                try fileManager.removeItem(at: stagedURL)
            }

            try fileManager.moveItem(at: location, to: stagedURL)
            continuation?.resume(returning: Result(stagedFileURL: stagedURL))
            finish()
        } catch {
            continuation?.resume(throwing: error)
            finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didBecomeInvalidWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            finish()
        }
    }

    private func finish() {
        session?.finishTasksAndInvalidate()
        session = nil
        continuation = nil
    }

    private func makeStagedDownloadURL() throws -> URL {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let stagingDirectory = cachesDirectory.appendingPathComponent("ModelDownloads", isDirectory: true)

        if !fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        }

        return stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("gguf")
    }
}
