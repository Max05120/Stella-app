//
//  TurnDetector.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  TurnDetector.swift
//  Stella
//
//  Determines when a complete user utterance begins and ends.
//
//  VAD answers:
//      "Is speech happening in this frame?"
//
//  TurnDetector answers:
//      "Has the user's complete conversational turn ended?"
//
//  These are deliberately separate responsibilities.
//

import Foundation

final class TurnDetector {

    // MARK: - Utterance

    struct Utterance: Sendable {

        /// Complete mono Float32 audio that should eventually
        /// be passed to Whisper.
        let samples: [Float]

        let sampleRate: Double

        /// Approximate duration of the completed utterance.
        let duration: TimeInterval
    }

    // MARK: - Event

    enum Event: Sendable {

        /// A new user turn has begun.
        case speechStarted

        /// A complete turn has ended and is ready for transcription.
        case speechEnded(Utterance)
    }

    // MARK: - Configuration

    struct Configuration: Sendable {

        /// Speech shorter than this is treated as accidental noise.
        var minimumSpeechDuration: TimeInterval = 0.20

        /// Silence required after established speech before the
        /// utterance is considered complete.
        ///
        /// Intentionally much longer than Stella's previous ~0.7 sec.
        var endpointSilenceDuration: TimeInterval = 1.78

        /// Audio retained immediately before speech begins.
        ///
        /// This prevents the first consonant/word being clipped when
        /// VAD takes a moment to confirm speech.
        var preRollDuration: TimeInterval = 0.25

        /// Maximum length of one utterance as a defensive bound.
        var maximumUtteranceDuration: TimeInterval = 30
    }

    // MARK: - Dependencies

    private let vad: VoiceActivityDetector

    // MARK: - Configuration

    private let configuration: Configuration

    // MARK: - State

    private enum State {
        case waiting
        case speaking
    }

    private var state: State = .waiting

    // MARK: - Buffers

    private var preRollSamples: [Float] = []
    private var utteranceSamples: [Float] = []

    // MARK: - Timing

    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    private var currentSampleRate: Double?

    // MARK: - Init

    init(
        vad: VoiceActivityDetector = VoiceActivityDetector(),
        configuration: Configuration = Configuration()
    ) {

        self.vad = vad
        self.configuration = configuration
    }

    // MARK: - Process Capture Frame

    func process(
        frame: AudioCaptureEngine.CaptureFrame
    ) -> Event? {

        process(
            samples: frame.samples,
            sampleRate: frame.sampleRate
        )
    }

    // MARK: - Process Samples

    func process(
        samples: [Float],
        sampleRate: Double
    ) -> Event? {

        guard !samples.isEmpty,
              sampleRate > 0 else {
            return nil
        }

        handleSampleRateChangeIfNeeded(
            sampleRate
        )

        let frameDuration =
            Double(samples.count) / sampleRate

        let vadResult = vad.process(
            samples: samples
        )

        switch state {

        case .waiting:

            return processWaitingState(
                samples: samples,
                sampleRate: sampleRate,
                frameDuration: frameDuration,
                isSpeech: vadResult.isSpeech
            )

        case .speaking:

            return processSpeakingState(
                samples: samples,
                sampleRate: sampleRate,
                frameDuration: frameDuration,
                isSpeech: vadResult.isSpeech
            )
        }
    }

    // MARK: - Waiting

    private func processWaitingState(
        samples: [Float],
        sampleRate: Double,
        frameDuration: TimeInterval,
        isSpeech: Bool
    ) -> Event? {

        if isSpeech {

            state = .speaking

            utteranceSamples = preRollSamples
            utteranceSamples.append(
                contentsOf: samples
            )

            preRollSamples.removeAll(
                keepingCapacity: true
            )

            speechDuration = frameDuration
            silenceDuration = 0

            return .speechStarted
        }

        appendToPreRoll(
            samples,
            sampleRate: sampleRate
        )

        return nil
    }

    // MARK: - Speaking

    private func processSpeakingState(
        samples: [Float],
        sampleRate: Double,
        frameDuration: TimeInterval,
        isSpeech: Bool
    ) -> Event? {

        utteranceSamples.append(
            contentsOf: samples
        )

        if isSpeech {

            speechDuration += frameDuration
            silenceDuration = 0

        } else {

            silenceDuration += frameDuration
        }

        let utteranceDuration =
            Double(utteranceSamples.count)
            /
            sampleRate

        // Defensive upper limit.
        if utteranceDuration >=
            configuration.maximumUtteranceDuration {

            return finishUtterance(
                sampleRate: sampleRate
            )
        }

        guard silenceDuration >=
                configuration.endpointSilenceDuration else {

            return nil
        }

        // Reject tiny accidental sounds.
        guard speechDuration >=
                configuration.minimumSpeechDuration else {

            resetTurnState()

            return nil
        }

        return finishUtterance(
            sampleRate: sampleRate
        )
    }

    // MARK: - Finish Utterance

    private func finishUtterance(
        sampleRate: Double
    ) -> Event {

        let samples = utteranceSamples

        let duration =
            Double(samples.count)
            /
            sampleRate

        let utterance = Utterance(
            samples: samples,
            sampleRate: sampleRate,
            duration: duration
        )

        resetTurnState()

        return .speechEnded(
            utterance
        )
    }

    // MARK: - Pre Roll

    private func appendToPreRoll(
        _ samples: [Float],
        sampleRate: Double
    ) {

        preRollSamples.append(
            contentsOf: samples
        )

        let maximumSamples = Int(
            configuration.preRollDuration
            *
            sampleRate
        )

        guard maximumSamples > 0 else {

            preRollSamples.removeAll(
                keepingCapacity: true
            )

            return
        }

        if preRollSamples.count > maximumSamples {

            let excess =
                preRollSamples.count
                -
                maximumSamples

            preRollSamples.removeFirst(
                excess
            )
        }
    }

    // MARK: - Sample Rate

    private func handleSampleRateChangeIfNeeded(
        _ sampleRate: Double
    ) {

        guard let existing =
                currentSampleRate else {

            currentSampleRate = sampleRate
            return
        }

        guard existing != sampleRate else {
            return
        }

        // A device switch may change microphone sample rate.
        // Never mix different sample-rate buffers inside one utterance.
        reset()

        currentSampleRate = sampleRate
    }

    // MARK: - Reset Turn

    private func resetTurnState() {

        state = .waiting

        utteranceSamples.removeAll(
            keepingCapacity: true
        )

        preRollSamples.removeAll(
            keepingCapacity: true
        )

        speechDuration = 0
        silenceDuration = 0
    }

    // MARK: - Public Reset

    func reset() {

        resetTurnState()

        currentSampleRate = nil

        vad.reset()
    }
}
