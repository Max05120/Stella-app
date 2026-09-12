//
//  StellaConversationOrchestrator.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  StellaConversationOrchestrator.swift
//  Stella
//
//  Coordinates Stella's new voice conversation pipeline.
//
//  IMPORTANT:
//  This is the replacement architecture being built beside the
//  existing VoiceConversationManager.
//
//  It does not yet perform:
//  - Whisper transcription
//  - backend requests
//  - TTS playback
//  - wake-word detection
//  - barge-in
//
//  Those components will be migrated in later phases.
//

import Foundation

final class StellaConversationOrchestrator: @unchecked Sendable {

    // MARK: - Dependencies
    
    private let webRTCProcessor: WebRTCAudioProcessor
    private let audioCaptureEngine: AudioCaptureEngine
    private let turnDetector: TurnDetector
    private let stateController: ConversationStateController
    private var whisperTranscriber: WhisperTranscriber?

    // MARK: - Audio Subscription

    private var audioListenerID: UUID?

    // MARK: - Init

    init(
        turnDetector: TurnDetector = TurnDetector(),
        stateController: ConversationStateController =
            ConversationStateController()
    ) {
        let processor = WebRTCAudioProcessor()

        self.webRTCProcessor = processor

        self.audioCaptureEngine =
            AudioCaptureEngine(
                preprocessor: processor
            )

        self.turnDetector = turnDetector
        self.stateController = stateController
    }
    
    deinit {
        shutdown()
    }

    // MARK: - Public State

    var state: ConversationState {
        stateController.state
    }

    // MARK: - Start

    /// Starts the new conversation pipeline.
    ///
    /// During Phase 3 testing we manually enter listening mode.
    /// Wake-word activation will replace this later.
    func startDebugConversation() throws {

        guard audioListenerID == nil else {

            print(
                "[CONVERSATION] already running"
            )

            return
        }
        
        if whisperTranscriber == nil {

            whisperTranscriber =
                try WhisperTranscriber()
        }
        
        turnDetector.reset()

        // The real architecture will eventually begin in standby:
        //
        // standby
        //   -> wakeWordDetected
        //   -> greeting
        //   -> greetingFinished
        //   -> listening
        //
        // For this controlled test we simulate those events.

        if stateController.state == .standby {

            stateController.handle(
                .wakeWordDetected
            )

            stateController.handle(
                .greetingFinished
            )
        }

        guard stateController.state == .listening else {

            print(
                "[CONVERSATION] cannot start capture while state = \(stateController.state.rawValue)"
            )

            return
        }

        audioListenerID =
            audioCaptureEngine.addListener {
                [weak self] frame in

                self?.handleAudioFrame(
                    frame
                )
            }

        do {

            try audioCaptureEngine.start()

            print(
                "[CONVERSATION] debug conversation started"
            )

            print(
                "[CONVERSATION] listening"
            )

        } catch {

            removeAudioListener()

            stateController.handle(
                .reset
            )

            throw error
        }
    }

    // MARK: - Stop

    func shutdown() {

        removeAudioListener()

        audioCaptureEngine.stop()

        turnDetector.reset()

        if stateController.state != .standby {

            stateController.handle(
                .endConversation
            )
        }

        print(
            "[CONVERSATION] shutdown"
        )
    }

    // MARK: - Audio

    private func handleAudioFrame(
        _ frame: AudioCaptureEngine.CaptureFrame
    ) {

        // During this phase, audio should only create user turns
        // while Stella is listening.
        //
        // Later, speaking-state audio will also be consumed by the
        // barge-in detector after WebRTC AEC3.

        guard stateController.state == .listening else {
            return
        }

        guard let event =
                turnDetector.process(
                    frame: frame
                ) else {

            return
        }

        handleTurnEvent(
            event
        )
    }

    // MARK: - Turn Events

    private func handleTurnEvent(
        _ event: TurnDetector.Event
    ) {

        switch event {

        case .speechStarted:

            print(
                "[CONVERSATION] user speech started"
            )

        case .speechEnded(let utterance):

            handleCompletedUtterance(
                utterance
            )
        }
    }

    // MARK: - Completed Utterance

    private func handleCompletedUtterance(
        _ utterance: TurnDetector.Utterance
    ) {

        print(
            String(
                format:
                    "[CONVERSATION] user turn completed — %.2fs — %d samples",
                utterance.duration,
                utterance.samples.count
            )
        )

        let transition =
            stateController.handle(
                .userTurnCompleted
            )

        switch transition {

        case .transitioned(
            from: .listening,
            to: .transcribing
        ):

            beginTranscriptionBoundary(
                utterance
            )

        case .transitioned,
             .unchanged,
             .rejected:

            break
        }
    }

    // MARK: - Transcription Boundary

    /// This is intentionally a boundary rather than a real Whisper
    /// implementation.
    ///
    /// Phase 4 will replace this method's placeholder behavior with:
    ///
    ///     completed utterance
    ///          ↓
    ///     WhisperTranscriber
    ///          ↓
    ///     transcript
    ///          ↓
    ///     .transcriptionCompleted
    ///
    /// Whisper will receive the COMPLETE utterance once.
    private func beginTranscriptionBoundary(
        _ utterance: TurnDetector.Utterance
    ) {

        print(
            "[CONVERSATION] transcription started"
        )

        guard let whisperTranscriber else {

            print(
                "[CONVERSATION] Whisper unavailable"
            )

            stateController.handle(
                .reset
            )

            return
        }

        // IMPORTANT:
        //
        // Whisper must never execute inside AVAudioEngine's
        // realtime microphone callback.
        //
        // We hand the completed utterance off to an asynchronous
        // task instead.

        Task { [weak self] in

            guard let self else {
                return
            }

            do {

                let transcript =
                    try await whisperTranscriber.transcribe(
                        utterance: utterance
                    )

                await self.handleTranscript(
                    transcript
                )

            } catch {

                await self.handleTranscriptionFailure(
                    error
                )
            }
        }
    }
    
    // MARK: - Transcript

    private func handleTranscript(
        _ transcript: String
    ) async {

        guard stateController.state == .transcribing else {

            print(
                "[CONVERSATION] discarded stale transcript while state = \(stateController.state.rawValue)"
            )

            return
        }

        let cleanedTranscript =
            transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cleanedTranscript.isEmpty else {

            print(
                "[CONVERSATION] empty transcription"
            )

            // No useful user utterance was recognized.
            //
            // For now return to listening by resetting the debug
            // conversation state through the normal state model.
            //
            // We'll improve this recovery path later.

            stateController.handle(
                .reset
            )

            return
        }

        print(
            "[CONVERSATION] transcript: \(cleanedTranscript)"
        )

        let result =
            stateController.handle(
                .transcriptionCompleted
            )

        switch result {

        case .transitioned(
            from: .transcribing,
            to: .thinking
        ):

            print(
                "[CONVERSATION] backend boundary reached"
            )

            print(
                "[CONVERSATION] ready for routing/reasoning"
            )

        case .transitioned,
             .unchanged,
             .rejected:

            break
        }
    }

    private func handleTranscriptionFailure(
        _ error: Error
    ) async {

        guard stateController.state == .transcribing else {
            return
        }

        print(
            "[CONVERSATION] transcription failed:",
            error.localizedDescription
        )

        stateController.handle(
            .reset
        )
    }
    
    // MARK: - Listener Cleanup

    private func removeAudioListener() {

        guard let audioListenerID else {
            return
        }

        audioCaptureEngine.removeListener(
            audioListenerID
        )

        self.audioListenerID = nil
    }

    // MARK: - Debug

    func debugPrintState() {

        print(
            "[CONVERSATION] state = \(state.rawValue)"
        )
    }
}
