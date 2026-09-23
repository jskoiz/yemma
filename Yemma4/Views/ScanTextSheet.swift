import SwiftUI
import Vision
import VisionKit

/// Camera pages are recognized locally and discarded after the review text is returned.
struct ScanTextSheet: UIViewControllerRepresentable {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }
    let onRecognizedText: (String) -> Void
    let onCancel: () -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: VNDocumentCameraViewController, coordinator: Coordinator) {
        coordinator.cancel()
        controller.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        private let parent: ScanTextSheet
        private var task: Task<Void, Never>?
        private var cancelled = false

        init(parent: ScanTextSheet) { self.parent = parent }

        func cancel() {
            cancelled = true
            task?.cancel()
            task = nil
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            cancel()
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            cancel()
            parent.onFailure("The camera scan could not finish. Please try again.")
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard task == nil else { return }
            guard scan.pageCount <= 8 else {
                parent.onFailure("Scan up to 8 pages at a time.")
                return
            }
            let progress = UIActivityIndicatorView(style: .large)
            progress.center = controller.view.center
            progress.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            progress.accessibilityLabel = "Reading scanned text"
            progress.isAccessibilityElement = true
            controller.view.addSubview(progress)
            progress.startAnimating()
            task = Task { [weak self] in
                guard let self else { return }
                defer { progress.removeFromSuperview(); self.task = nil }
                do {
                    var pages: [String] = []
                    var characterCount = 0
                    for index in 0..<scan.pageCount {
                        guard !Task.isCancelled, !self.cancelled else { return }
                        guard let image = scan.imageOfPage(at: index).cgImage else {
                            throw ScanError.unreadable
                        }
                        let page = try await Task.detached(priority: .userInitiated) {
                            let request = VNRecognizeTextRequest()
                            request.recognitionLevel = .accurate
                            request.usesLanguageCorrection = true
                            try VNImageRequestHandler(cgImage: image).perform([request])
                            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                        }.value
                        guard !Task.isCancelled, !self.cancelled else { return }
                        characterCount += page.count + (pages.isEmpty ? 0 : 2)
                        guard characterCount <= 12_000 else { throw ScanError.tooLong }
                        pages.append(page)
                    }
                    let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw ScanError.noText }
                    guard !self.cancelled else { return }
                    self.parent.onRecognizedText(text)
                } catch {
                    guard !Task.isCancelled, !self.cancelled else { return }
                    self.parent.onFailure((error as? ScanError)?.message ?? "The scanned text could not be read. Try a clearer scan.")
                }
            }
        }
    }

    private enum ScanError: Error {
        case unreadable, tooLong, noText
        var message: String {
            switch self {
            case .unreadable: return "A scanned page could not be read. Please try again."
            case .tooLong: return "This scan contains more than 12,000 characters. Scan fewer pages at a time."
            case .noText: return "No text was found. Try a clearer scan with good lighting."
            }
        }
    }
}
