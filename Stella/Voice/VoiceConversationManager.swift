//
//  VoiceConversationManager.swift
//  Stella
//
//  Created by Harish Maheshwaran on 30/08/26.
//


import Foundation
import Combine

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
    
    let recorder = MicrophoneRecorder()
    
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
    
    private let bargeInPhrases: [String] = [
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
    
    init(
        backend: BackendManager
    ) {
        self.backend = backend
        self.output = VoiceOutputManager(sharedEngine: recorder.engine)
        
        loadWhisper()
        audioGraphReadyTask = Task {
                await output.prepare()
            }
    }
    
    func waitUntilAudioGraphReady() async {
        await audioGraphReadyTask?.value
    }
    
    var audioLevel: Float {
        recorder.level
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
                    
                } else if self.recorder.isRecording {
                    
                    self.spectrum =
                    self.recorder
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
        
        cancelCurrentWork()
        didBargeIn = false
//        isCapturingBargeIn = false
        conversationId = UUID().uuidString

        print("[VOICE] new conversation: \(conversationId)")
        
        transcript = ""
        responseText = ""
        
        state = .greeting
        
        startSpectrumUpdates()
        
        speak("Hey, I'm listening.", settingState: .greeting, allowBargeIn: false) {
            [weak self] in
            self?.startListening()
        }
    }
    
    func stopConversation() {
        
        cancelCurrentWork()
        
        stopSpectrumUpdates()
        
        if recorder.isRecording {
            _ = recorder.stop()
        }
        
        output.stop()
        
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

        if recorder.isRecording {
            _ = recorder.stop()
        }

        output.stop()

        transcript = ""
        responseText = ""

        state = .idle

        print(
            "[VOICE] voice session ended — Stella idle"
        )
        onVoiceSessionEnded?()
    }
    
    private func cancelCurrentWork() {
        
        silenceTask?.cancel()
        silenceTask = nil
        
        conversationTask?.cancel()
        conversationTask = nil
        
        spectrumTask?.cancel()
        spectrumTask = nil
    }
    
    // MARK: - Listening
    
    private func startListening() {
        
        guard backend.status == .ready else {
            
            state = .error(
                "Stella's backend isn't ready."
            )
            
            return
        }
        
        transcript = ""

        do {
            
            if !recorder.isRecording {
                try recorder.start()
            }
            
            state = .listening
            
            print(
                "[VOICE] listening"
            )
            
            startSpectrumUpdates()
            startSilenceDetection()
            
        } catch {
            
            state = .error(
                error.localizedDescription
            )
        }
        
    }
    
    // MARK: - Silence detection
    
    private func startSilenceDetection() {
        
        silenceTask?.cancel()
        
        silenceTask = Task {
            [weak self] in
            
            guard let self else {
                return
            }
            
            var heardSpeech = false
            
            var speechStartedAt:
            Date?
            
            var lastSpeechAt:
            Date?
            
            var speechStartSample:
                Int?
            
            while !Task.isCancelled {
                
                try? await Task.sleep(
                    for: .milliseconds(100)
                )
                
                guard !Task.isCancelled else {
                    return
                }
                
                guard
                    self.state == .listening,
                    self.recorder.isRecording
                else {
                    return
                }
                
                let level =
                self.recorder.level
                
                let now = Date()
                
                if level > self.speechThreshold {

                    if candidateSpeechStartedAt == nil {
                        candidateSpeechStartedAt = now
                    }

                    if !heardSpeech,
                       let candidateStart = candidateSpeechStartedAt,
                       now.timeIntervalSince(candidateStart) >= self.speechConfirmationDuration {

                        heardSpeech = true
                        speechStartedAt = candidateStart
                        speechStartSample = self.recorder.sampleCount

                        print(
                            "[VOICE] confirmed speech at sample \(speechStartSample ?? 0)"
                        )
                    }

                    if heardSpeech {
                        lastSpeechAt = now
                    }

                } else {

                    // Noise spike wasn't sustained long enough.
                    if !heardSpeech {
                        candidateSpeechStartedAt = nil
                    }
                }
                
                guard
                    heardSpeech,
                    let speechStartedAt,
                    let lastSpeechAt
                else {
                    continue
                }
                
                let speechLength =
                now.timeIntervalSince(
                    speechStartedAt
                )
                
                let silenceLength =
                now.timeIntervalSince(
                    lastSpeechAt
                )
                
                if (
                    speechLength >=
                    self.minimumSpeechDuration
                    &&
                    silenceLength >=
                    self.silenceDuration
                ) {
                    
                    print(
                        "[VOICE] end of speech"
                    )
                    
                    self.silenceTask = nil
                    
                    self.finishUtterance(
                        speechStartSample:
                        speechStartSample
                    )
                    
                    return
                }
            }
        }
    }
    
    // MARK: - Whisper
    
    private func finishUtterance(
        speechStartSample: Int?
    ) {
        
        guard recorder.isRecording else {
            return
        }
        
        silenceTask?.cancel()
        silenceTask = nil
        stopSpectrumUpdates()
        
        let recordedSamples =
            recorder.stop()

        guard !recordedSamples.isEmpty else {
            startListening()
            return
        }

        // Whisper runs at 16 kHz.
        //
        // Keep 400 ms before VAD's detected speech onset.
        // This preserves initial consonants/breath while removing
        // potentially several seconds of irrelevant room audio.
        let preRollSamples = 6_400

        let samples: [Float]

        if let speechStartSample {

            let startIndex =
                max(
                    0,
                    speechStartSample
                        - preRollSamples
                )

            if startIndex <
                recordedSamples.count
            {

                samples =
                    Array(
                        recordedSamples[
                            startIndex...
                        ]
                    )

            } else {

                samples =
                    recordedSamples
            }

        } else {

            samples =
                recordedSamples
        }

        print(
            "[VOICE] trimmed audio \(recordedSamples.count) → \(samples.count) samples"
        )
        
        var squareSum: Float = 0
        for s in samples { squareSum += s * s }
        let utteranceRMS = sqrt(squareSum / Float(samples.count))
        
        guard utteranceRMS >
                speechThreshold * 1.3
        else {

            print(
                "[VOICE] discarding, too quiet: \(utteranceRMS)"
            )

            startListening()
            return
        
        }
        
        state = .transcribing
        
        conversationTask = Task {
            [weak self] in
            
            guard let self,
                  let whisper =
                    self.whisper
            else {
                return
            }
            
            do {
                
                let started = Date()
                
                let text =
                try await whisper
                    .transcribe(
                        samples: samples
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
                    "[VOICE] STT \(Int(elapsed))ms: \(text)"
                )
                
                let cleaned =
                self.cleanTranscript(
                    text
                )

                guard !cleaned.isEmpty else {
                    self.startListening()
                    return
                }

                self.transcript = cleaned

                // Handle Stella-local commands before sending anything
                // to the Python/backend conversation.
                if self.isSleepCommand(cleaned) {

                    print(
                        "[VOICE] sleep command detected: \(cleaned)"
                    )

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

        state = settingState

        startSpectrumUpdates()

        if allowBargeIn {

            watchForBargeIn()

        } else {

            bargeInTask?.cancel()
            bargeInTask = nil
        }

        output.speak(text) { [weak self] in

            guard let self else {
                return
            }

            self.bargeInTask?.cancel()
            self.bargeInTask = nil
            
            if self.didBargeIn {
                        return
                    }
            then()
        }
    }
    
    private func isBargeInPhrase(
        _ text: String
    ) -> Bool {

        let normalized =
            text
                .lowercased()
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .trimmingCharacters(
                    in: .punctuationCharacters
                )

        guard !normalized.isEmpty else {
            return false
        }

        for phrase in bargeInPhrases {

            if normalized == phrase {
                return true
            }

            if normalized.hasPrefix(
                phrase + " "
            ) {
                return true
            }
        }

        return false
    }
    
    private func watchForBargeIn() {

        bargeInTask?.cancel()
        bargeInTask = nil

        bargeInTask = Task {
            [weak self] in

            guard let self else {
                return
            }

            // ----------------------------------------
            // Absolute safety gate.
            // Barge-in ONLY exists while Stella
            // is speaking an answer.
            // ----------------------------------------

            guard
                self.state == .speaking,
                self.output.isSpeaking
            else {
                return
            }

            do {

                if !self.recorder.isRecording {
                    try self.recorder.start()
                }

            } catch {

                print(
                    "[BARGE] mic failed:",
                    error.localizedDescription
                )

                return
            }


            // Let playback settle before looking for
            // possible interruption.
            try? await Task.sleep(
                for: .milliseconds(400)
            )

            var candidateStartedAt: Date?


            while !Task.isCancelled {

                guard
                    self.state == .speaking,
                    self.output.isSpeaking
                else {
                    return
                }

                try? await Task.sleep(
                    for: .milliseconds(30)
                )

                guard !Task.isCancelled else {
                    return
                }

                let level =
                    self.recorder.level


                // ------------------------------------
                // Stage 1:
                // acoustic candidate ONLY
                // ------------------------------------

                if level >
                    self.bargeInThreshold
                {

                    if candidateStartedAt == nil {

                        candidateStartedAt =
                            Date()

                        print(
                            "[BARGE] acoustic candidate \(level)"
                        )
                    }

                    guard
                        let candidateStart =
                            candidateStartedAt
                    else {
                        continue
                    }

                    let durationMs =
                        Date()
                            .timeIntervalSince(
                                candidateStart
                            ) * 1000


                    guard
                        durationMs >=
                        Double(
                            self.bargeInConfirmMs
                        )
                    else {
                        continue
                    }


                    // --------------------------------
                    // Something sustained was heard.
                    //
                    // DO NOT stop Stella yet.
                    // Verify the words first.
                    // --------------------------------

                    print(
                        "[BARGE] verifying candidate"
                    )

                    let recorded =
                        self.recorder.stop()

                    candidateStartedAt = nil


                    guard !recorded.isEmpty else {

                        self.restartBargeMonitoringMic()
                        continue
                    }


                    // Only inspect the most recent
                    // ~1.25 sec, not everything Stella
                    // has said since playback started.
                    let maxSamples =
                        20_000

                    let verificationSamples =
                        Array(
                            recorded.suffix(
                                maxSamples
                            )
                        )


                    guard
                        let whisper =
                            self.whisper
                    else {
                        return
                    }


                    do {

                        let text =
                            try await whisper
                                .transcribe(
                                    samples:
                                        verificationSamples
                                )

                        guard !Task.isCancelled else {
                            return
                        }


                        print(
                            "[BARGE] heard: \(text)"
                        )


                        // --------------------------------
                        // Stage 2:
                        // LANGUAGE GATE
                        // --------------------------------

                        if self.isBargeInPhrase(
                            text
                        ) {

                            print(
                                "[BARGE] keyword confirmed: \(text)"
                            )

                            self.didBargeIn = true

                            // NOW Stella is allowed
                            // to stop speaking.
                            self.output.stop()

                            self.bargeInTask = nil


                            // The verification recording
                            // contained speaker bleed +
                            // interrupt keyword.
                            //
                            // Throw it away.
                            // Start CLEAN user recording.
                            if self.recorder.isRecording {

                                _ =
                                self.recorder.stop()
                            }


                            self.startListening()

                            print(
                                "[BARGE] interruption accepted"
                            )

                            return

                        } else {

                            // CRITICAL:
                            //
                            // This audio NEVER reaches
                            // sendToStella().
                            //
                            // Stella probably heard
                            // herself / room noise.
                            print(
                                "[BARGE] rejected: no interrupt keyword"
                            )


                            // Continue monitoring while
                            // Stella keeps speaking.
                            self.restartBargeMonitoringMic()
                        }

                    } catch {

                        print(
                            "[BARGE] verification failed:",
                            error.localizedDescription
                        )

                        self.restartBargeMonitoringMic()
                    }
                }

                else {

                    candidateStartedAt =
                        nil
                }
            }
        }
    }
    
    private func restartBargeMonitoringMic() {

        guard
            state == .speaking,
            output.isSpeaking
        else {
            return
        }

        do {

            if !recorder.isRecording {
                try recorder.start()
            }

        } catch {

            print(
                "[BARGE] couldn't restart mic:",
                error.localizedDescription
            )
        }
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
    
    // MARK: - Conversation ID
    
    private static func
    loadOrCreateConversationId()
    -> String
    {
        
        let key =
        "voiceConversationId"
        
        if let existing =
            UserDefaults.standard
            .string(forKey: key)
        {
            return existing
        }
        
        let id =
        UUID().uuidString
        
        UserDefaults.standard.set(
            id,
            forKey: key
        )
        
        return id
    }
}
   
    

