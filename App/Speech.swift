import Foundation
import AVFoundation
import NaturalLanguage
import Speech
import Observation

/// Microphone to text, using on-device recognition where the language supports it.
@MainActor @Observable
final class VoiceInput {
    enum State: Equatable { case idle, denied(String), listening }

    var state: State = .idle
    var transcript = ""

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening }

    func toggle() async {
        if isListening { stop() } else { await start() }
    }

    func start() async {
        guard !isListening else { return }
        guard await Self.authorize() else {
            state = .denied(String(localized: "Microphone or speech recognition permission is missing. Enable it in iOS Settings."))
            return
        }
        let locale = Locale.current
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
        guard let recognizer, recognizer.isAvailable else {
            state = .denied(String(localized: "Speech recognition is not available right now."))
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            transcript = ""
            state = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch {
            state = .denied(String(localized: "Could not start the microphone: \(error.localizedDescription)"))
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if state == .listening { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Reads assistant replies aloud with the system voice. On-device, so it costs nothing.
@MainActor @Observable
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    var isSpeaking = false

    func speak(_ text: String) {
        stop()
        let cleaned = Self.strippedForSpeech(text)
        guard !cleaned.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = Self.voice(for: cleaned)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    /// The agent answers in whatever language the user wrote, which need not be the phone's.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let candidates = [recognizer.dominantLanguage?.rawValue, Locale.current.language.languageCode?.identifier]
        for language in candidates.compactMap({ $0 }) {
            if let voice = AVSpeechSynthesisVoice(language: language) { return voice }
            let regional = AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(language + "-") }
            if let regional { return regional }
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Paths and markdown read badly out loud.
    static func strippedForSpeech(_ text: String) -> String {
        var out = text
        for token in ["**", "*", "`", "#"] { out = out.replacingOccurrences(of: token, with: "") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
