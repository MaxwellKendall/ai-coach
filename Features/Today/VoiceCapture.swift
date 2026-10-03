import AVFoundation
import Speech

/// Hold-to-talk on-device dictation. Audio never leaves the phone.
@MainActor @Observable
final class VoiceCapture {
    private(set) var transcript = ""
    private(set) var listening = false
    /// Set when permission is denied or on-device recognition isn't available.
    private(set) var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var starting = false

    func start() async {
        guard !starting, !listening else { return }
        starting = true
        defer { starting = false }
        transcript = ""
        problem = nil
        guard await Self.authorized() else { problem = "Allow the microphone and speech recognition in Settings to log by voice."; return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
            problem = "Speech recognition isn't available on this iPhone."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try Self.startTap(engine, feeding: request)
        } catch {
            problem = "Couldn't start the microphone."
            return
        }
        listening = true
        task = Self.recognize(recognizer, request) { [weak self] text in self?.transcript = text }
    }

    // The audio tap, speech results and permission replies arrive on background queues. Under Swift 6 a closure
    // written inside this @MainActor class is main-actor isolated and traps there, so they are built nonisolated.

    private nonisolated static func startTap(_ engine: AVAudioEngine, feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No usable microphone (or one still held by another app) reports a zero format, and installing a tap on it throws.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private nonisolated static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              heard: @escaping @MainActor (String) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in heard(text) }
        }
    }

    /// Stops listening and returns everything heard.
    func stop() -> String {
        guard listening else { return transcript }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        return transcript
    }

    private nonisolated static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }
}
