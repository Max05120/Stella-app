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
    
    private let output =
    VoiceOutputManager()
    
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
    
    private let conversationId =
    VoiceConversationManager
        .loadOrCreateConversationId()
    
    // Tune these later using real usage.
    private let speechThreshold: Float = 0.012
    
    private let silenceDuration:
    TimeInterval = 1.05
    
    private let minimumSpeechDuration:
    TimeInterval = 0.22
    
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
        "goodbye stella"
    ]
    
    init(
        backend: BackendManager
    ) {
        self.backend = backend
        
        loadWhisper()
        Task {
            await output.prepare()
        }
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
        
        transcript = ""
        responseText = ""
        
        state = .greeting
        
        startSpectrumUpdates()
        
        output.speak(
            "Hey, I'm listening."
        ) { [weak self] in
            guard let self else {
                return
            }
            
            self.startListening()
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
        
        
        guard !recorder.isRecording else {
            return
        }
        
        transcript = ""
        
        do {
            
            try recorder.start()
            
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
                
                if level >
                    self.speechThreshold
                {
                    if !heardSpeech {

                        heardSpeech = true
                        speechStartedAt = now

                        speechStartSample =
                            self.recorder.sampleCount

                        print(
                            "[VOICE] speech detected at sample \(speechStartSample ?? 0)"
                        )
                    }
                    
                    lastSpeechAt = now
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

        output.speak(
            response
        ) {
            [weak self] in

            guard let self else {
                return
            }

            self.endVoiceSession()
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
        state = .speaking
        
        startSpectrumUpdates()
        
        output.speak(
            text
        ) {
            [weak self] in
            
            guard let self else {
                return
            }
            
            self.startListening()
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
   
    

