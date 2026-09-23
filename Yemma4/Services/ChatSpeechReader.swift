import AVFoundation
import Observation

/// Reads assistant responses aloud without recording or sending any chat data.
@MainActor
@Observable
final class ChatSpeechReader: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false

    @ObservationIgnored private var synthesizerStorage: AVSpeechSynthesizer?
    @ObservationIgnored private var activeUtteranceID: ObjectIdentifier?

    private var synthesizer: AVSpeechSynthesizer {
        if let synthesizerStorage { return synthesizerStorage }
        let value = AVSpeechSynthesizer()
        value.delegate = self
        synthesizerStorage = value
        return value
    }

    /// Stops the current utterance before starting the replacement.
    func speak(_ text: String) {
        stop()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmedText)
        activeUtteranceID = ObjectIdentifier(utterance)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        _ = synthesizerStorage?.stopSpeaking(at: .immediate)
        activeUtteranceID = nil
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishIfCurrent(id) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishIfCurrent(id) }
    }

    private func finishIfCurrent(_ id: ObjectIdentifier) {
        guard activeUtteranceID == id else { return }
        activeUtteranceID = nil
        isSpeaking = false
    }
}
