//
//  VoiceConversationManager.swift
//  Stella
//
//  Created by Harish Maheshwaran on 30/08/26.
//


import Foundation
import Combine
import AVFoundation

@MainActor
final class VoiceConversationManager:
    ObservableObject
{
    enum State: Equatable {
        case loading
        case idle
        case greeting
        case listening
        case transcribing
        case thinking
        case speaking
        case error(String)
    }
    
    @Published private(set)
    var state: State = .loading
    
    @Published private(set)
    var transcript = ""
    
    @Published private(set)
    var responseText = ""
    
    @Published private(set)
    var spectrum: AudioSpectrum = .zero
     
    private let webRTCProcessor: WebRTCAudioProcessor
    private let audioCaptureEngine: AudioCaptureEngine
    private let turnDetector = TurnDetector()
    private let bargeInDetector = BargeInDetector()
    
    private var bargeInArmed = false
    private var bargeDiagnosticsCounter = 0
    private var bargeInArmTask: Task<Void, Never>?
    private var currentSpeechAllowsBargeIn = false
    
    private var interruptionSamples: [Float] = []
    private var interruptionSampleRate: Double?
    private let interruptionHistoryDuration: Double = 0.8
//    private var bargeInPreRoll:
//        [AudioCaptureEngine.CaptureFrame] = []
//
//    // WebRTC capture is 10 ms/frame,
//    // so 40 frames ≈ 400 ms.
//    private let bargeInPreRollFrameLimit = 40

    private var audioListenerID: UUID?
//    let audioCapture: AudioCaptureCoordinator
    
    // TEMPORARY: legacy recorder used only by WakeWordListener.
    // Conversation audio uses AudioCaptureEngine.
//    let recorder = MicrophoneRecorder()
    lazy var wakeWordListener = WakeWordListener(
        captureEngine: audioCaptureEngine
    )
    private let output: VoiceOutputManager
    
    private let backend:
    BackendManager
    
    private let api =
    APIClient()
    
    var onVoiceSessionEnded: (() -> Void)?
    
    private var whisper:
    WhisperTranscriber?
    
    private var silenceTask:
    Task<Void, Never>?
    
    private var conversationTask:
    Task<Void, Never>?
    
    private var spectrumTask:
    Task<Void, Never>?
    
    var candidateSpeechStartedAt: Date?
    
    //    private let conversationId =
    //    VoiceConversationManager
    //        .loadOrCreateConversationId()
    private var conversationId = UUID().uuidString
    
    // Tune these later using real usage.
    private let speechThreshold: Float = 0.025
    private let speechConfirmationDuration: TimeInterval = 0.25
    private let silenceDuration:
    TimeInterval = 0.7
    private let minimumSpeechDuration:
    TimeInterval = 0.22
    
    // Barge-in behaviour
    private let bargeInThreshold: Float = 0.040
    private let bargeInConfirmMs: Int = 140
    private var bargeInTask: Task<Void, Never>?
    //    private let bargeInBleedFactor: Float = 1.6
    private var didBargeIn = false
    //    private var isCapturingBargeIn = false
    private var lastBargeVoteLogTime: TimeInterval = 0
    
    private let bargeInIntents: [String] = [
        "wait",
        "wait stella",
        "actually",
        "actually wait",
        "hold on",
        "hold up",
        "hang on",
        "stop",
        "stop stella",
        "no wait",
        "that's not it",
        "that is not it",
        "that's wrong",
        "that is wrong",
        "let me finish",
        "one second",
        "just a second"
    ]
    
    private let sleepCommands: [String] = [
        "we're done stella",
        "we are done stella",
        "we're done here stella",
        "we are done here stella",
        "that's all stella",
        "that is all stella",
        "go idle",
        "go back to idle",
        "go to idle",
        "go to sleep stella",
        "sleep stella",
        "stop listening stella",
        "you can stop listening",
        "bye stella",
        "bye, bye, stella",
        "goodbye stella"
    ]
    
    private static let hallucinationFragments: [String] = [
        "thank you for watching",
        "thanks for watching",
        "please subscribe",
        "subscribe to our channel",
        "like and subscribe",
        "don't forget to subscribe",
        "see you in the next video",
        "see you next time"
    ]
    
    private var audioGraphReadyTask: Task<Void, Never>?
    private var thermalStateObserver: NSObjectProtocol?
//    let webRTCProcessor = WebRTCAudioProcessor()
    
    init(
        backend: BackendManager
    ) {
        self.backend = backend

        let processor = WebRTCAudioProcessor()
        self.webRTCProcessor = processor
        
        let scheduledProcessor = ScheduledWebRTCAudioProcessor(processor: processor)

        let captureEngine =
            AudioCaptureEngine(
                preprocessor: scheduledProcessor
            )

        self.audioCaptureEngine = captureEngine

//        let playbackEngine = AVAudioEngine()

        self.output =
            VoiceOutputManager(
                sharedEngine: captureEngine.playbackEngine,
                audioPreprocessor: scheduledProcessor
            )
        
        self.output.onPlaybackStarted = {
            [weak self] in

            guard let self else {
                return
            }

            self.handlePlaybackStarted()
        }

        loadWhisper()

        audioGraphReadyTask = Task {
            await output.prepare()
        }

        observeThermalState()
    }

    deinit {
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(
                thermalStateObserver
            )
        }
    }

    // MARK: - Thermal State
    //
    // Cheap, always-on diagnostic: two consecutive real sessions
    // showed AEC3's delay estimate swinging wildly (and once
    // resetting from a buffer overrun) only late in the longest,
    // most chunk-heavy turn — right where Kokoro's own chunk
    // generation time also ballooned (2s → 7s). That pattern looks
    // like system-wide load or thermal throttling building up over
    // a long conversation, not something specific to the audio
    // pipeline. This makes it directly visible in the log instead
    // of guessed at.
    private func observeThermalState() {

        print(
            "[THERMAL] initial state: " +
            Self.describeThermalState(
                ProcessInfo.processInfo.thermalState
            )
        )

        thermalStateObserver =
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in

                print(
                    "[THERMAL] state changed: " +
                    Self.describeThermalState(
                        ProcessInfo.processInfo.thermalState
                    )
                )
            }
    }

    private static func describeThermalState(
        _ state: ProcessInfo.ThermalState
    ) -> String {

        switch state {

        case .nominal:
            return "nominal"

        case .fair:
            return "fair"

        case .serious:
            return "serious"

        case .critical:
            return "critical"

        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }
    
    func waitUntilAudioGraphReady() async {
        await audioGraphReadyTask?.value
    }
    
//    var audioLevel: Float {
//        recorder.level
//    }
    
    var statusText: String {
        switch state {
        case .loading:
            return "Loading Stella..."
            
        case .idle:
            return "Waiting for Stella..."
            
        case .greeting:
            return "Stella"
            
        case .listening:
            return "I'm listening..."
            
        case .transcribing:
            return "Understanding..."
            
        case .thinking:
            return "Thinking..."
            
        case .speaking:
            return "Speaking..."
            
        case .error(let message):
            return message
        }
    }
    
    
    
    // MARK: - Startup
    
    private func loadWhisper() {
        Task {
            do {
                whisper =
                try WhisperTranscriber()
                
                state = .idle
                
                print(
                    "[VOICE] Whisper ready"
                )
                
            } catch {
                state = .error(
                    error.localizedDescription
                )
            }
        }
    }
    private func startSpectrumUpdates() {
        spectrumTask?.cancel()
        
        spectrumTask = Task {
            [weak self] in
            
            guard let self else {
                return
            }
            
            while !Task.isCancelled {
                
                try? await Task.sleep(
                    for:
                            .milliseconds(33)
                )
                
                guard !Task.isCancelled else {
                    return
                }
                
                if self.output.isSpeaking {
                    
                    self.spectrum =
                    self.output
                        .spectrumSnapshot()
                    
                } else {
                    
                    self.spectrum =
                        .zero
                }
            }
        }
        
    }
    
    private func stopSpectrumUpdates() {
        
        spectrumTask?.cancel()
        spectrumTask = nil
        
        spectrum = .zero
    }
    
    // MARK: - Conversation lifecycle
    
    func beginConversation() {
        
        guard whisper != nil else {
            return
        }
        wakeWordListener.stop()
        cancelCurrentWork()
        didBargeIn = false
        //        isCapturingBargeIn = false
        conversationId = UUID().uuidString
        
        print("[VOICE] new conversation: \(conversationId)")
        
        transcript = ""
        responseText = ""
        
        #if DEBUG
        AECDiagnosticRecorder.shared.start(
            label: "shared WebRTC capture; live barge-in"
        )
        #endif
        
        do {
            try audioCaptureEngine.start()
            print("[AUDIO] shared capture active for conversation")
        } catch {
            state = .error(
                error.localizedDescription
            )

            print(
                "[AUDIO] failed to start shared engine:",
                error.localizedDescription
            )
            
            #if DEBUG
            AECDiagnosticRecorder.shared.finish()
            #endif

            return
        }
        
        state = .greeting
        
        startSpectrumUpdates()
        
        speak("Hey Max, I'm listening.", settingState: .greeting, allowBargeIn: false) {
            [weak self] in
            self?.startListening()
        }
    }
    
    func stopConversation() {
        
        cancelCurrentWork()
        
        stopSpectrumUpdates()
        
        if let audioListenerID {
            audioCaptureEngine.removeListener(
                audioListenerID
            )
            self.audioListenerID = nil
        }

//        audioCaptureEngine.stop()
        
        output.stop()
        
        #if DEBUG
        AECDiagnosticRecorder.shared.finish()
        #endif
        
        state = .idle
        
        print(
            "[VOICE] conversation stopped"
        )
    }
    
    private func endVoiceSession() {
        
        cancelCurrentWork()
        
        stopSpectrumUpdates()
        didBargeIn = false
        //        isCapturingBargeIn = false
        
        if let audioListenerID {
            audioCaptureEngine.removeListener(
                audioListenerID
            )
            self.audioListenerID = nil
        }

//        audioCaptureEngine.stop()
        
        output.stop()
        
        #if DEBUG
        AECDiagnosticRecorder.shared.finish()
        #endif
        
        transcript = ""
        responseText = ""
        
        state = .idle
        
        print(
            "[VOICE] voice session ended — Stella idle"
        )
        onVoiceSessionEnded?()
    }
    
    func shutdownAudio() {
        // Prevent recovery from restarting wake recognition.
        wakeWordListener.stop()

        // Stop conversation work and playback first.
        stopConversation()

        // Only application shutdown stops the shared capture graph.
        audioCaptureEngine.stop()
    }
    
    private func cancelCurrentWork() {
        
        clearInterruptionAudio()
        
        silenceTask?.cancel()
        silenceTask = nil
        
        conversationTask?.cancel()
        conversationTask = nil
        
        spectrumTask?.cancel()
        spectrumTask = nil
    }
    
    // MARK: - Listening
    
    private func startListening() {
        
        clearInterruptionAudio()
        guard backend.status == .ready else {
            state = .error(
                "Stella's backend isn't ready."
            )
            return
        }
        
        transcript = ""

        turnDetector.reset()
        let listeningSessionID = conversationId
        if let audioListenerID {
            audioCaptureEngine.removeListener(
                audioListenerID
            )
            self.audioListenerID = nil
        }
        
        audioListenerID =
            audioCaptureEngine.addListener {
                [weak self] frame in

                guard let self else {
                    return
                }

                DispatchQueue.main.async {
                    guard self.conversationId == listeningSessionID else { return }
                    switch self.state {

                    case .listening:
                        self.handleTurnDetectorFrame(frame)

//                        if let event =
//                            self.turnDetector.process(
//                                frame: frame
//                            )
//                        {
//                            switch event {
//
//                            case .speechStarted:
//
//                                print(
//                                    "[VOICE] turn detector speech started"
//                                )
//
//                            case .speechEnded(let utterance):
//
//                                print(
//                                    "[VOICE] turn completed — \(String(format: "%.2f", utterance.duration))s"
//                                )
//
//                                self.handleCompletedUtterance(
//                                    utterance
//                                )
//                            }
//                        }

                    case .speaking:
                        guard self.currentSpeechAllowsBargeIn,
                              self.output.isSpeaking
                        else {
                            break
                        }

                        // Retain the entire callback before evaluating its sub-frames.
                        self.retainInterruptionAudio(frame)

                        if !self.bargeInArmed {
                            if self.bargeInArmTask != nil {
                                self.bargeInDetector.calibrate(frame: frame)
                            }
                            break
                        }

                        let decisions = self.bargeInDetector.process(
                            frame: frame,
                            observeOnly: false
                        )

                        if let confirmed = decisions.first(where: { $0.triggered }) {
                            print(
                                "[BARGE] confirmed — " +
                                "speechFrames=" +
                                "\(confirmed.evidence.speechGateFramesInWindow)/" +
                                "\(confirmed.evidence.framesInWindow)"
                            )

                            self.handleNaturalBargeIn()
                        }

                    default:
                        break
                    }
                }
            }

        state = .listening

        print(
            "[VOICE] listening — new audio pipeline"
        )

        startSpectrumUpdates()
    }
    
    private func handleTurnDetectorFrame(
        _ frame: AudioCaptureEngine.CaptureFrame
    ) {
        guard let event =
            turnDetector.process(
                frame: frame
            )
        else {
            return
        }

        switch event {

        case .speechStarted:
            print(
                "[VOICE] turn detector speech started"
            )

        case .speechEnded(let utterance):
            print(
                String(
                    format:
                        "[VOICE] turn completed — %.2fs",
                    Double(utterance.samples.count)
                        / Double(utterance.sampleRate)
                )
            )

            handleCompletedUtterance(
                utterance
            )
        }
    }
    
    private func clearInterruptionAudio() {
        interruptionSamples.removeAll(keepingCapacity: true)
        interruptionSampleRate = nil
    }

    private func retainInterruptionAudio(
        _ frame: AudioCaptureEngine.CaptureFrame
    ) {
        guard frame.sampleRate > 0, !frame.samples.isEmpty else {
            return
        }

        if interruptionSampleRate != frame.sampleRate {
            clearInterruptionAudio()
            interruptionSampleRate = frame.sampleRate
        }

        interruptionSamples.append(contentsOf: frame.samples)

        let capacity = max(
            1,
            Int(frame.sampleRate * interruptionHistoryDuration)
        )

        if interruptionSamples.count > capacity {
            interruptionSamples.removeFirst(
                interruptionSamples.count - capacity
            )
        }
    }
    // MARK: - Silence detection
    
//    private func startSilenceDetection() {
//
//        silenceTask?.cancel()
//
//        silenceTask = Task {
//            [weak self] in
//
//            guard let self else {
//                return
//            }
//
//            var heardSpeech = false
//
//            var speechStartedAt:
//            Date?
//
//            var lastSpeechAt:
//            Date?
//
//            var speechStartSample:
//            Int?
//
//            while !Task.isCancelled {
//
//                try? await Task.sleep(
//                    for: .milliseconds(100)
//                )
//
//                guard !Task.isCancelled else {
//                    return
//                }
//
////                guard
////                    self.state == .listening,
//////                    self.recorder.isRecording
////                else {
////                    return
////                }
////
////                let level =
////                self.recorder.level
//
//                let now = Date()
//
////                if level > self.speechThreshold {
//
//                    if candidateSpeechStartedAt == nil {
//                        candidateSpeechStartedAt = now
//                    }
//
//                    if !heardSpeech,
//                       let candidateStart = candidateSpeechStartedAt,
//                       now.timeIntervalSince(candidateStart) >= self.speechConfirmationDuration {
//
//                        heardSpeech = true
//                        speechStartedAt = candidateStart
//                        speechStartSample = self.recorder.sampleCount
//
//                        print(
//                            "[VOICE] confirmed speech at sample \(speechStartSample ?? 0)"
//                        )
//                    }
//
//                    if heardSpeech {
//                        lastSpeechAt = now
//                    }
//
//                } else {
//
//                    // Noise spike wasn't sustained long enough.
//                    if !heardSpeech {
//                        candidateSpeechStartedAt = nil
//                    }
//                }
//
//                guard
//                    heardSpeech,
//                    let speechStartedAt,
//                    let lastSpeechAt
//                else {
//                    continue
//                }
//
//                let speechLength =
//                now.timeIntervalSince(
//                    speechStartedAt
//                )
//
//                let silenceLength =
//                now.timeIntervalSince(
//                    lastSpeechAt
//                )
//
//                if (
//                    speechLength >=
//                    self.minimumSpeechDuration
//                    &&
//                    silenceLength >=
//                    self.silenceDuration
//                ) {
//
//                    print(
//                        "[VOICE] end of speech"
//                    )
//
//                    self.silenceTask = nil
//
//                    self.finishUtterance(
//                        speechStartSample:
//                            speechStartSample
//                    )
//
//                    return
//                }
//            }
//        }
//    }
//
    
    
//    -----------------------
    
    
    private func handleCompletedUtterance(
        _ utterance: TurnDetector.Utterance
    ) {

        guard state == .listening else {
            return
        }

        state = .transcribing

//        if let audioListenerID {
//            audioCaptureEngine.removeListener(
//                audioListenerID
//            )
//            self.audioListenerID = nil
//        }

//        audioCaptureEngine.stop()

        conversationTask = Task {
            [weak self] in

            guard let self,
                  let whisper = self.whisper
            else {
                return
            }

            do {
                let started = Date()

                let text =
                    try await whisper.transcribe(
                        utterance: utterance
                    )

                guard !Task.isCancelled else {
                    return
                }

                let elapsed =
                    Date()
                        .timeIntervalSince(started)
                        * 1000

                print(
                    "[VOICE] STT \(Int(elapsed))ms: \(text)"
                )

                let cleaned =
                    self.cleanTranscript(text)

                guard !cleaned.isEmpty else {
                    self.startListening()
                    return
                }

                self.transcript = cleaned

                if self.isSleepCommand(cleaned) {
                    self.sayIdleFarewell()
                    return
                }

                await self.sendToStella(
                    cleaned
                )

            } catch {
                self.state =
                    .error(
                        error.localizedDescription
                    )
            }
        }
    }
    
    
    
    // MARK: - Playback Helper
    private func handlePlaybackStarted() {
        guard state == .speaking,
              output.isSpeaking,
              currentSpeechAllowsBargeIn,
              !bargeInArmed,
              bargeInArmTask == nil
        else {
            return
        }

        // Discard any baseline learned before actual render audio.
        bargeInDetector.reset()
        bargeDiagnosticsCounter = 0

        print("[BARGE] playback calibration started")

        bargeInArmTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.state == .speaking,
                  self.output.isSpeaking,
                  self.currentSpeechAllowsBargeIn
            else {
                return
            }

            self.bargeInArmed = true
            self.bargeInArmTask = nil

            print(
                "[BARGE] detector armed — thermal=" +
                Self.describeThermalState(
                    ProcessInfo.processInfo.thermalState
                )
            )
        }
    }
    
    // MARK: - Whisper
    
//    private func finishUtterance(
//        speechStartSample: Int?
//    ) {
//
//        guard recorder.isRecording else {
//            return
//        }
//
//        silenceTask?.cancel()
//        silenceTask = nil
//        stopSpectrumUpdates()
//
//        let recordedSamples =
//        recorder.stop()
//
//        audioCapture.release(
//            .conversation
//        )
//
//        guard !recordedSamples.isEmpty else {
//            startListening()
//            return
//        }
//
//        // Whisper runs at 16 kHz.
//        //
//        // Keep 400 ms before VAD's detected speech onset.
//        // This preserves initial consonants/breath while removing
//        // potentially several seconds of irrelevant room audio.
//        let preRollSamples = 6_400
//
//        let samples: [Float]
//
//        if let speechStartSample {
//
//            let startIndex =
//            max(
//                0,
//                speechStartSample
//                - preRollSamples
//            )
//
//            if startIndex <
//                recordedSamples.count
//            {
//
//                samples =
//                Array(
//                    recordedSamples[
//                        startIndex...
//                    ]
//                )
//
//            } else {
//
//                samples =
//                recordedSamples
//            }
//
//        } else {
//
//            samples =
//            recordedSamples
//        }
//
//        print(
//            "[VOICE] trimmed audio \(recordedSamples.count) → \(samples.count) samples"
//        )
//
//        var squareSum: Float = 0
//        for s in samples { squareSum += s * s }
//        let utteranceRMS = sqrt(squareSum / Float(samples.count))
//
//        guard utteranceRMS >
//                speechThreshold * 1.3
//        else {
//
//            print(
//                "[VOICE] discarding, too quiet: \(utteranceRMS)"
//            )
//
//            startListening()
//            return
//
//        }
//
//        state = .transcribing
//
//        conversationTask = Task {
//            [weak self] in
//
//            guard let self,
//                  let whisper =
//                    self.whisper
//            else {
//                return
//            }
//
//            do {
//
//                let started = Date()
//
//                let text =
//                try await whisper
//                    .transcribe(
//                        samples: samples
//                    )
//
//                guard !Task.isCancelled else {
//                    return
//                }
//
//                let elapsed =
//                Date()
//                    .timeIntervalSince(
//                        started
//                    ) * 1000
//
//                print(
//                    "[VOICE] STT \(Int(elapsed))ms: \(text)"
//                )
//
//                let cleaned =
//                self.cleanTranscript(
//                    text
//                )
//
//                guard !cleaned.isEmpty else {
//                    self.startListening()
//                    return
//                }
//
//                self.transcript = cleaned
//
//                // Handle Stella-local commands before sending anything
//                // to the Python/backend conversation.
//                if self.isSleepCommand(cleaned) {
//
//                    print(
//                        "[VOICE] sleep command detected: \(cleaned)"
//                    )
//
//                    self.sayIdleFarewell()
//                    return
//                }
//
//                await self.sendToStella(
//                    cleaned
//                )
//
//            } catch {
//
//                self.state =
//                    .error(
//                        error.localizedDescription
//                    )
//            }
//        }
//    }
    
    private func sayIdleFarewell() {
        
        let responses = [
            "See ya.",
            "Call me when you need me.",
            "Aye aye, cap.",
            "Stella going idle now.",
            "Catch you later.",
            "I'll be around.",
            "Going quiet.",
            "Back to idle."
        ]
        
        let response =
        responses.randomElement()
        ?? "See ya."
        
        state = .speaking
        
        startSpectrumUpdates()
        
        speak(
            response,
            allowBargeIn: false
        ) { [weak self] in
            self?.endVoiceSession()
        }
    }
    // MARK: - Stella API
    
    private func sendToStella(
        _ text: String
    ) async {
        
        guard backend.status == .ready else {
            
            state = .error(
                "Stella's backend isn't ready."
            )
            
            return
        }
        
        state = .thinking
        
        let started = Date()
        
        do {
            
            let response =
            try await api.chat(
                message: text,
                conversationId:
                    conversationId
            )
            
            guard !Task.isCancelled else {
                return
            }
            
            let elapsed =
            Date()
                .timeIntervalSince(
                    started
                ) * 1000
            
            print(
                "[VOICE] Stella \(Int(elapsed))ms"
            )
            
            responseText =
            response.answer
            
            speakResponse(
                response.answer
            )
            
        } catch {
            
            state = .error(
                error.localizedDescription
            )
        }
    }
    
    // MARK: - Speech output
    
    private func speakResponse(
        _ text: String
    ) {
        
        didBargeIn = false
        
        speak(
            text,
            settingState: .speaking,
            allowBargeIn: true
        ) {
            [weak self] in
            
            guard let self else {
                return
            }
            
            if self.didBargeIn {
                return
            }
            
            self.startListening()
        }
    }
    
    private func speak(
        _ text: String,
        settingState: State = .speaking,
        allowBargeIn: Bool = false,
        then: @escaping () -> Void
    ) {
        
        clearInterruptionAudio()
        state = settingState

        bargeInDetector.reset()

        bargeInArmTask?.cancel()
        bargeInArmTask = nil

        bargeInArmed = false
        currentSpeechAllowsBargeIn = allowBargeIn

        output.speak(text) { [weak self] in

            guard let self else {
                return
            }

            self.bargeInArmTask?.cancel()
            self.bargeInArmTask = nil

            self.bargeInArmed = false
            self.currentSpeechAllowsBargeIn = false

            self.bargeInTask?.cancel()
            self.bargeInTask = nil

            then()
        }
    }
    
    private func isBargeInPhrase(
        _ text: String
    ) -> Bool {
        
        let normalized =
        text
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        
        guard !normalized.isEmpty else {
            return false
        }
        
        // Explicit address is mandatory.
        guard normalized.contains("stella") else {
            return false
        }
        
        for intent in bargeInIntents {
            
            let stellaFirst =
            "stella \(intent)"
            
            let stellaLast =
            "\(intent) stella"
            
            if normalized == stellaFirst ||
                normalized == stellaLast
            {
                return true
            }
            
            // Allows:
            // "Stella wait I meant Python"
            // "Wait Stella I meant Python"
            if normalized.hasPrefix(
                stellaFirst + " "
            ) ||
                normalized.hasPrefix(
                    stellaLast + " "
                ) {
                return true
            }
        }
        
        return false
    }
    
    private func handleNaturalBargeIn() {
        guard state == .speaking,
              bargeInArmed,
              currentSpeechAllowsBargeIn,
              let rate = interruptionSampleRate,
              !interruptionSamples.isEmpty
        else {
            return
        }

        let retained = interruptionSamples
        clearInterruptionAudio()

        // Invalidate speaking state before stopping playback.
        didBargeIn = true
        bargeInArmed = false
        currentSpeechAllowsBargeIn = false

        bargeInArmTask?.cancel()
        bargeInArmTask = nil

        state = .listening

        // Stops playback/synthesis, not AudioCaptureEngine.
        output.stop()

        turnDetector.beginConfirmedInterruption(
            samples: retained,
            sampleRate: rate
        )

        bargeInDetector.reset()

        print(String(
            format:
                "[BARGE] TTS stopped; retained %.0f ms — listening",
            Double(retained.count) / rate * 1000
        ))
    }
    
//    private func appendBargeInPreRoll(
//        _ frame: AudioCaptureEngine.CaptureFrame
//    ) {
//        bargeInPreRoll.append(frame)
//
//        let overflow =
//            bargeInPreRoll.count
//            - bargeInPreRollFrameLimit
//
//        if overflow > 0 {
//            bargeInPreRoll.removeFirst(overflow)
//        }
//    }
//    private func watchForBargeIn() {
//
//        bargeInTask?.cancel()
//        bargeInTask = nil
//
//        bargeInTask = Task {
//            [weak self] in
//
//            guard let self else {
//                return
//            }
//
//            // ----------------------------------------
//            // Absolute safety gate.
//            // Barge-in ONLY exists while Stella
//            // is speaking an answer.
//            // ----------------------------------------
//
//            guard
//                self.state == .speaking,
//                self.output.isSpeaking
//            else {
//                return
//            }
//
//            self.audioCapture.claim(
//                .interruption
//            )
//
//            do {
//
//                if !self.recorder.isRecording {
//                    try self.recorder.start()
//                }
//
//            } catch {
//
//                print(
//                    "[BARGE] mic failed:",
//                    error.localizedDescription
//                )
//
//                return
//            }
//
//
//            // Let playback settle before looking for
//            // possible interruption.
//            try? await Task.sleep(
//                for: .milliseconds(400)
//            )
//
//            var candidateStartedAt: Date?
//
//
//            while !Task.isCancelled {
//
//                guard
//                    self.state == .speaking,
//                    self.output.isSpeaking
//                else {
//                    return
//                }
//
//                try? await Task.sleep(
//                    for: .milliseconds(30)
//                )
//
//                guard !Task.isCancelled else {
//                    return
//                }
//
//                let level =
//                self.recorder.level
//
//
//                // ------------------------------------
//                // Stage 1:
//                // acoustic candidate ONLY
//                // ------------------------------------
//
//                if level >
//                    self.bargeInThreshold
//                {
//
//                    if candidateStartedAt == nil {
//
//                        candidateStartedAt =
//                        Date()
//
//                        print(
//                            "[BARGE] acoustic candidate \(level)"
//                        )
//                    }
//
//                    guard
//                        let candidateStart =
//                            candidateStartedAt
//                    else {
//                        continue
//                    }
//
//                    let durationMs =
//                    Date()
//                        .timeIntervalSince(
//                            candidateStart
//                        ) * 1000
//
//
//                    guard
//                        durationMs >=
//                            Double(
//                                self.bargeInConfirmMs
//                            )
//                    else {
//                        continue
//                    }
//
//
//                    // --------------------------------
//                    // Something sustained was heard.
//                    //
//                    // DO NOT stop Stella yet.
//                    // Verify the words first.
//                    // --------------------------------
//
//                    print(
//                        "[BARGE] verifying candidate"
//                    )
//
//                    let recorded =
//                    self.recorder.stop()
//
//                    candidateStartedAt = nil
//
//
//                    guard !recorded.isEmpty else {
//
//                        self.restartBargeMonitoringMic()
//                        continue
//                    }
//
//
//                    // Only inspect the most recent
//                    // ~1.25 sec, not everything Stella
//                    // has said since playback started.
//                    let maxSamples =
//                    20_000
//
//                    let verificationSamples =
//                    Array(
//                        recorded.suffix(
//                            maxSamples
//                        )
//                    )
//
//
//                    guard
//                        let whisper =
//                            self.whisper
//                    else {
//                        return
//                    }
//
//
//                    do {
//
//                        let text =
//                        try await whisper
//                            .transcribe(
//                                samples:
//                                    verificationSamples
//                            )
//
//                        guard !Task.isCancelled else {
//                            return
//                        }
//
//
//                        print(
//                            "[BARGE] heard: \(text)"
//                        )
//
//
//                        // --------------------------------
//                        // Stage 2:
//                        // LANGUAGE GATE
//                        // --------------------------------
//
//                        if self.isBargeInPhrase(
//                            text
//                        ) {
//
//                            print(
//                                "[BARGE] keyword confirmed: \(text)"
//                            )
//
//                            self.didBargeIn = true
//
//                            // NOW Stella is allowed
//                            // to stop speaking.
//                            self.output.stop()
//
//                            self.bargeInTask = nil
//
//
//                            // The verification recording
//                            // contained speaker bleed +
//                            // interrupt keyword.
//                            //
//                            // Throw it away.
//                            // Start CLEAN user recording.
//                            if let audioListenerID {
//                                audioCaptureEngine.removeListener(
//                                    audioListenerID
//                                )
//                                self.audioListenerID = nil
//                            }
//
//                            audioCaptureEngine.stop()
//
//                            self.audioCapture.release(
//                                .interruption
//                            )
//
//                            self.startListening()
//
//                            print(
//                                "[BARGE] interruption accepted"
//                            )
//
//                            return
//
//                        } else {
//
//                            // CRITICAL:
//                            //
//                            // This audio NEVER reaches
//                            // sendToStella().
//                            //
//                            // Stella probably heard
//                            // herself / room noise.
//                            print(
//                                "[BARGE] rejected: no interrupt keyword"
//                            )
//
//
//                            // Continue monitoring while
//                            // Stella keeps speaking.
//                            self.restartBargeMonitoringMic()
//                        }
//
//                    } catch {
//
//                        print(
//                            "[BARGE] verification failed:",
//                            error.localizedDescription
//                        )
//
//                        self.restartBargeMonitoringMic()
//                    }
//                }
//
//                else {
//
//                    candidateStartedAt =
//                    nil
//                }
//            }
//        }
//    }
//
//    private func restartBargeMonitoringMic() {
//
//        guard
//            state == .speaking,
//            output.isSpeaking
//        else {
//            return
//        }
//
//        do {
//
//            if !recorder.isRecording {
//                try recorder.start()
//            }
//
//        } catch {
//
//            print(
//                "[BARGE] couldn't restart mic:",
//                error.localizedDescription
//            )
//        }
//    }
    
    // MARK: - Local voice commands
    
    private func isSleepCommand(_ text: String) -> Bool {
        
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return sleepCommands.contains { command in
            normalized.contains(command)
        }
    }
    // MARK: - Transcript cleanup
    
    private func cleanTranscript(
        _ text: String
    ) -> String {
        
        var cleaned = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        
        let upper = cleaned.uppercased()
        
        if cleaned.isEmpty ||
            upper.contains("[BLANK_AUDIO]") ||
            upper.contains("[BLANK AUDIO]")
        {
            return ""
        }
        
        let normalizedForHallucinationCheck = cleaned
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if Self.hallucinationFragments.contains(where: { normalizedForHallucinationCheck.contains($0) }) {
            print("[VOICE] discarding likely hallucination: \(cleaned)")
            return ""
        }
        
        cleaned = cleaned.replacingOccurrences(
            of: "Stiller",
            with: "Stella",
            options: .caseInsensitive
        )
        
        return cleaned
    }
    
}
