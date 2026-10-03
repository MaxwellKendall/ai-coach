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

    func start() async {
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
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            problem = "Couldn't start the microphone."
            return
        }
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            let text = result?.bestTranscription.formattedString
            Task { @MainActor in if let text { self?.transcript = text } }
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

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }
}
