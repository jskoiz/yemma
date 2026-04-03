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
        refreshLocalState()
    }

    public func downloadModel() async {
        guard !isDownloading else { return }

        refreshLocalState()
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
            let destinationURL = modelFileURL
            let resumeData = loadResumeDataIfAvailable()
            let downloadResult = try await ModelDownloadCoordinator(
                downloadURL: modelDownloadURL,
                resumeData: resumeData,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = progress
                    }
                }
            ).download()

            try persistDownloadedFile(from: downloadResult.tempFileURL, to: destinationURL)
            clearResumeData()

            downloadProgress = 1
            isDownloaded = true
            modelPath = destinationURL.path
            error = nil
        } catch {
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                saveResumeData(resumeData)
            }
            self.error = Self.describe(error)
            refreshLocalState()
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

        refreshLocalState()
    }

    private func refreshLocalState() {
        let url = modelFileURL
        if fileManager.fileExists(atPath: url.path) {
            isDownloaded = true
            modelPath = url.path
            downloadProgress = max(downloadProgress, 1)
        } else {
            isDownloaded = false
            modelPath = nil
            if !isDownloading {
                downloadProgress = 0
            }
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

    private func loadResumeDataIfAvailable() -> Data? {
        guard fileManager.fileExists(atPath: resumeDataURL.path) else {
            return nil
        }

        return try? Data(contentsOf: resumeDataURL)
    }

    private func saveResumeData(_ data: Data) {
        do {
            try data.write(to: resumeDataURL, options: [.atomic])
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func clearResumeData() {
        guard fileManager.fileExists(atPath: resumeDataURL.path) else { return }
        try? fileManager.removeItem(at: resumeDataURL)
    }

    private func persistDownloadedFile(from tempURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
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

private final class ModelDownloadCoordinator: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    struct Result {
        let tempFileURL: URL
    }

    private let downloadURL: URL
    private let resumeData: Data?
    private let progressHandler: @Sendable (Double) -> Void

    private var session: URLSession?
    private var continuation: CheckedContinuation<Result, Error>?

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
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        continuation?.resume(returning: Result(tempFileURL: location))
        finish()
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
}
