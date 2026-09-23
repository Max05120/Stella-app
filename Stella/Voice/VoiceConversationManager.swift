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
    private var bargeInArmTask: Task<Void, Never>?
    private var currentSpeechAllowsBargeIn = false
    
    private var interruptionSamples: [Float] = []
    private var interruptionSampleRate: Double?
    private let interruptionHistoryDuration: Double = 0.8
    
    private var isShuttingDown = false
    private var standbyEnabled = false
    private var standbyTask: Task<Void, Never>?

    private var audioListenerID: UUID?

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
    
    
    private var conversationTask:
    Task<Void, Never>?
    
    private var spectrumTask:
    Task<Void, Never>?
    
    
    private var conversationId = UUID().uuidString

    
    // Barge-in behaviour
    private var didBargeIn = false
    
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
            guard !isShuttingDown else { return }
            do {
                whisper =
                try WhisperTranscriber()
                
                state = .idle
                scheduleWakeStandby()
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
        
        guard !isShuttingDown,
              state == .idle,
              whisper != nil
        else {
            return
        }
        wakeWordListener.stop()
        cancelCurrentWork()
        didBargeIn = false
        conversationId = UUID().uuidString
        
        print("[VOICE] new conversation: \(conversationId)")
        
        transcript = ""
        responseText = ""
        
        do {
            try audioCaptureEngine.start()
            print("[AUDIO] shared capture active for conversation")
        } catch {
            recoverFromConversationError(
                "Shared capture failed: \(error.localizedDescription)"
            )
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
        endVoiceSession()
    }

    private func endVoiceSession() {
        cancelCurrentWork()
        stopSpectrumUpdates()

        if let audioListenerID {
            audioCaptureEngine.removeListener(audioListenerID)
            self.audioListenerID = nil
        }

        output.stop()
        turnDetector.reset()
        bargeInDetector.reset()
        didBargeIn = false

        #if DEBUG
        AECDiagnosticRecorder.shared.finish()
        #endif

        transcript = ""
        responseText = ""
        state = .idle

        guard !isShuttingDown else { return }

        print("[VOICE] voice session ended — Stella idle")
        onVoiceSessionEnded?()
        scheduleWakeStandby()
    }
    
    func shutdownAudio() {
        guard !isShuttingDown else { return }

        // Set this before cancellation can deliver callbacks.
        isShuttingDown = true
        standbyEnabled = false

        wakeWordListener.stop()
        endVoiceSession()

        audioGraphReadyTask?.cancel()
        audioCaptureEngine.stop()

        print("[VOICE] audio shutdown complete")
    }
    
    func shutdownForApplicationExit() async {
        // Stops capture, playback, wake recognition, and session tasks.
        // Your existing shutdown guard prevents later restarts.
        shutdownAudio()

        if let transcriber = whisper {
            await transcriber.shutdown()
            whisper = nil
        }

        print("[VOICE] application shutdown complete")
    }
    
    func startWakeStandby() async {
        guard !isShuttingDown else { return }

        await waitUntilAudioGraphReady()

        guard !Task.isCancelled, !isShuttingDown else { return }

        let allowed = await wakeWordListener.requestPermissions()

        guard allowed,
              !Task.isCancelled,
              !isShuttingDown
        else {
            return
        }

        standbyEnabled = true
        scheduleWakeStandby()
    }

    private func scheduleWakeStandby() {
        standbyTask?.cancel()
        standbyTask = nil

        guard standbyEnabled,
              !isShuttingDown,
              whisper != nil,
              state == .idle
        else {
            return
        }

        let sessionID = conversationId

        standbyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  !self.isShuttingDown,
                  self.standbyEnabled,
                  self.state == .idle,
                  self.conversationId == sessionID
            else {
                return
            }

            self.standbyTask = nil
            print("[VOICE] returning to wake standby")
            self.wakeWordListener.start()
        }
    }

    private func recoverFromConversationError(_ message: String) {
        guard !isShuttingDown else { return }

        print("[VOICE] session failed: \(message)")
        endVoiceSession()
    }
    
    private func cancelCurrentWork() {
        // Invalidates already-queued capture and session callbacks.
        conversationId = UUID().uuidString

        standbyTask?.cancel()
        standbyTask = nil

        conversationTask?.cancel()
        conversationTask = nil

        spectrumTask?.cancel()
        spectrumTask = nil

        bargeInArmTask?.cancel()
        bargeInArmTask = nil

        bargeInArmed = false
        currentSpeechAllowsBargeIn = false

        clearInterruptionAudio()
    }
    
    // MARK: - Listening
    
    private func startListening() {
        
        guard !isShuttingDown else { return }
        clearInterruptionAudio()
        guard backend.status == .ready else {
            recoverFromConversationError(
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
        let sessionID = conversationId
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

                guard !Task.isCancelled,
                      !self.isShuttingDown,
                      self.conversationId == sessionID
                else {
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
                guard !Task.isCancelled,
                      !self.isShuttingDown,
                      self.conversationId == sessionID
                else {
                    return
                }

                self.recoverFromConversationError(
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
        
        guard !Task.isCancelled, !isShuttingDown else { return }
        let sessionID = conversationId
        guard backend.status == .ready else {
            recoverFromConversationError(
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
                    sessionID
            )
            
            guard !Task.isCancelled,
                  !isShuttingDown,
                  conversationId == sessionID
            else {
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
            guard !Task.isCancelled,
                  !isShuttingDown,
                  conversationId == sessionID
            else {
                return
            }

            recoverFromConversationError(
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
        guard !isShuttingDown else { return }
        let sessionID = conversationId
        clearInterruptionAudio()
        state = settingState

        bargeInDetector.reset()

        bargeInArmTask?.cancel()
        bargeInArmTask = nil

        bargeInArmed = false
        currentSpeechAllowsBargeIn = allowBargeIn

        output.speak(text) { [weak self] in

            guard let self,
                  !self.isShuttingDown,
                  self.conversationId == sessionID
            else {
                return
            }

            self.bargeInArmTask?.cancel()
            self.bargeInArmTask = nil

            self.bargeInArmed = false
            self.currentSpeechAllowsBargeIn = false


            then()
        }
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
