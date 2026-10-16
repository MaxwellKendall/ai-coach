import AVFoundation
import Speech

/// On-device dictation. Audio never leaves the phone.
///
/// FIT-134: the user ends it (Done, tapping the mic again, or letting go of a hold). Silence is only a backstop,
/// 5 s after the last word, and the listening veil shows it coming. Before, it ended 1.6 s after the transcript last
/// changed, so a pause to think cut the request in half. Transcription is iOS 26's SpeechAnalyzer: SpeechTranscriber
/// where the phone has it, else the dictation model.
@MainActor @Observable
final class VoiceCapture {
    /// What was said: the finished phrases, then the one still being heard.
    var transcript: String { (finished + " " + volatile).trimmingCharacters(in: .whitespaces) }
    /// A session is open: listening, or the words are being edited before they're sent.
    private(set) var listening = false
    /// Tapping the words stops the microphone so they can be fixed by hand, then sent.
    private(set) var editing = false
    /// When the last word was heard, or listening started; the backstop counts from here.
    private(set) var quietSince = Date.now
    /// Set when permission is denied or on-device recognition isn't available.
    private(set) var problem: String?
    /// Words the recognizer should expect, such as exercise names ("RDL", "Bulgarian Split Squat").
    var vocabulary: [String] = []

    /// After this long without a new word, what was said is sent.
    static let backstop: TimeInterval = 5
    /// With nothing said at all, listening ends after this long and nothing is sent.
    static let nothingSaid: TimeInterval = 10

    private var finished = ""
    private var volatile = ""
    private var startedAt = Date.now
    private var onDone: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var recognizerRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognizerTask: SFSpeechRecognitionTask?
    private var watch: Task<Void, Never>?
    private var starting = false
    /// The microphone's tap is installed; the input node is only touched then (with no microphone it can throw).
    private var tapped = false

    enum Failure: Error {
        case noTranscriber
        case noAudioFormat
        /// No usable microphone, or one still held by another app; its format says which.
        case noMicrophone(AVAudioFormat)
    }

    /// Starts listening; `onDone` gets what was said when the user ends it or the backstop does, never on Cancel or
    /// silence.
    func start(onDone: @escaping (String) -> Void) async {
        guard !starting, !listening else { return }
        starting = true
        defer { starting = false }
        finished = ""
        volatile = ""
        problem = nil
        editing = false
        guard await Self.authorized() else {
            VoiceLog.record("", "couldn't start: no permission")
            problem = "Allow the microphone and speech recognition in Settings to talk to the coach."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            do {
                try await startAnalyzer()
            } catch {
                // No SpeechTranscriber or dictation model here (the simulator, some phones): the older on-device recognizer.
                VoiceLog.record("", "SpeechAnalyzer couldn't start (\(error)), using SFSpeechRecognizer")
                stopAudio()
                try startRecognizer()
            }
        } catch {
            print("Voice capture couldn't start: \(error)")
            VoiceLog.record("", "couldn't start: \(error)")
            stopAudio()
            problem = "Couldn't start the microphone."
            return
        }
        self.onDone = onDone
        startedAt = .now
        quietSince = .now
        listening = true
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.checkSilence()
            }
        }
    }

    private func startAnalyzer() async throws {
        guard let module = await Self.module() else { throw Failure.noTranscriber }
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw Failure.noAudioFormat }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let context = AnalysisContext()
        if !vocabulary.isEmpty { context.contextualStrings[.general] = vocabulary }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        self.analyzer = analyzer
        self.input = input
        tapped = true
        try Self.startTap(engine, format: format) { input.yield(AnalyzerInput(buffer: $0)) }
        try await analyzer.start(inputSequence: stream)
        results = Self.results(of: module) { [weak self] text, final in self?.heard(text, final: final) }
    }

    private func startRecognizer() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else { throw Failure.noTranscriber }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        recognizerRequest = request
        // The request takes buffers from the audio thread; Apple's own samples append to it there.
        nonisolated(unsafe) let feeding = request
        tapped = true
        try Self.startTap(engine, format: nil) { feeding.append($0) }
        recognizerTask = Self.recognize(recognizer, request) { [weak self] text, final in self?.heard(text, final: final) }
    }

    #if DEBUG
    /// `-listen "swap bench for dumbbell bench"`: listening as if that was just said, for the simulator, which has no
    /// microphone.
    func pretend(_ said: String, onDone: @escaping (String) -> Void) {
        self.onDone = onDone
        finished = said
        volatile = ""
        startedAt = .now
        quietSince = .now
        listening = true
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.checkSilence()
            }
        }
    }
    #endif

    private func heard(_ text: String, final: Bool) {
        guard listening, !editing else { return }
        if final {
            finished = (finished + " " + text).trimmingCharacters(in: .whitespaces)
            volatile = ""
        } else {
            volatile = text
        }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { quietSince = .now }
    }

    private func checkSilence() {
        guard listening, !editing else { return }
        if transcript.isEmpty {
            if Date.now.timeIntervalSince(startedAt) >= Self.nothingSaid { _ = stop() }
        } else if Date.now.timeIntervalSince(quietSince) >= Self.backstop {
            finish(how: "silence")
        }
    }

    /// Ends listening and sends what was said (or `text`, when it was edited by hand).
    func finish(_ text: String? = nil, how: String = "done") {
        guard listening else { return }
        let said = (text ?? transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Date.now.timeIntervalSince(startedAt)
        let onDone = onDone
        teardown()
        VoiceLog.record(said, "heard in \(Int(seconds.rounded())) s, ended by \(how)\(text == nil ? "" : ", edited by hand")")
        if !said.isEmpty { onDone?(said) }
    }

    /// Stops the microphone and keeps the words on screen to be fixed by hand.
    func edit() {
        guard listening, !editing else { return }
        editing = true
        stopAudio()
    }

    /// Stops without sending (Cancel) and returns everything heard.
    func stop() -> String {
        let said = transcript
        guard listening else { return said }
        teardown()
        return said
    }

    private func teardown() {
        stopAudio()
        watch?.cancel()
        watch = nil
        onDone = nil
        listening = false
        editing = false
    }

    private func stopAudio() {
        if tapped {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        input?.finish()
        input = nil
        recognizerRequest?.endAudio()
        recognizerTask?.cancel()
        recognizerRequest = nil
        recognizerTask = nil
        let analyzer = analyzer, results = results
        self.analyzer = nil
        self.results = nil
        // The words on screen are what's sent; the analyzer just winds down.
        if analyzer != nil || results != nil {
            Task {
                await analyzer?.cancelAndFinishNow()
                results?.cancel()
            }
        }
    }

    // The audio tap, speech results and permission replies arrive on background queues. Under Swift 6 a closure
    // written inside this @MainActor class is main-actor isolated and traps there, so they are built nonisolated.

    private nonisolated static func module() async -> (any SpeechModule)? {
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
        return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
    }

    private nonisolated static func results(of module: any SpeechModule,
                                            heard: @escaping @MainActor (String, Bool) -> Void) -> Task<Void, Never> {
        Task.detached {
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await result in transcriber.results { await heard(String(result.text.characters), result.isFinal) }
                } else if let dictation = module as? DictationTranscriber {
                    for try await result in dictation.results { await heard(String(result.text.characters), result.isFinal) }
                }
            } catch {
                print("Speech results ended: \(error)")
            }
        }
    }

    /// Feeds the microphone to `feed`, converted to `format` when one is given.
    private nonisolated static func startTap(_ engine: AVAudioEngine, format: AVAudioFormat?,
                                             feed: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        // No usable microphone (or one still held by another app) reports a zero format, and installing a tap on it throws.
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw Failure.noMicrophone(natural) }
        let converter = format.flatMap { AVAudioConverter(from: natural, to: $0) }
        if format != nil, converter == nil { throw Failure.noMicrophone(natural) }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            guard let converter, let format else { return feed(buffer) }
            if let converted = convert(buffer, with: converter, to: format) { feed(converted) }
        }
        engine.prepare()
        try engine.start()
    }

    private nonisolated static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              heard: @escaping @MainActor (String, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString, final = result.isFinal
            Task { @MainActor in heard(text, final) }
        }
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private nonisolated static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }
}
