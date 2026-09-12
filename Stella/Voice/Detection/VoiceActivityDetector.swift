//
//  VoiceActivityDetector.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  VoiceActivityDetector.swift
//  Stella
//
//  Lightweight stateful voice activity detector.
//
//  This is responsible only for determining whether an incoming
//  audio frame appears to contain speech.
//
//  It does NOT decide when the user's complete turn has ended.
//  That belongs to TurnDetector.
//

import Foundation

final class VoiceActivityDetector {

    // MARK: - Result

    struct Result: Sendable {

        let isSpeech: Bool

        /// Root mean square energy of the current frame.
        let rms: Float

        /// Current adaptive estimate of background noise.
        let noiseFloor: Float

        /// Dynamic level that the current frame must exceed
        /// before it is considered speech.
        let speechThreshold: Float
    }

    // MARK: - Configuration

    struct Configuration: Sendable {

        /// Absolute minimum threshold.
        ///
        /// Prevents the adaptive floor becoming excessively sensitive
        /// in an extremely quiet environment.
        var minimumSpeechThreshold: Float = 0.008

        /// Speech threshold relative to estimated background noise.
        var noiseMultiplier: Float = 2.8

        /// Number of consecutive probable-speech frames required
        /// before entering the speech state.
        var speechAttackFrames: Int = 2

        /// Number of probable-silence frames required before leaving
        /// the speech state.
        ///
        /// This provides hysteresis so tiny dips inside words don't
        /// constantly toggle speech on/off.
        var speechReleaseFrames: Int = 4

        /// Speed at which the background-noise estimate adapts while
        /// we believe the user is silent.
        var noiseFloorLearningRate: Float = 0.04

        /// Initial assumed room noise.
        var initialNoiseFloor: Float = 0.003
    }

    // MARK: - Configuration

    private let configuration: Configuration

    // MARK: - State

    private var noiseFloor: Float

    private var speechFrameCount = 0
    private var silenceFrameCount = 0

    private var currentlySpeaking = false

    // MARK: - Init

    init(
        configuration: Configuration = Configuration()
    ) {

        self.configuration = configuration
        self.noiseFloor = configuration.initialNoiseFloor
    }

    // MARK: - Process

    func process(
        samples: [Float]
    ) -> Result {

        guard !samples.isEmpty else {

            return Result(
                isSpeech: currentlySpeaking,
                rms: 0,
                noiseFloor: noiseFloor,
                speechThreshold: currentSpeechThreshold
            )
        }

        let rms = calculateRMS(samples)

        let threshold = currentSpeechThreshold

        let probableSpeech = rms >= threshold

        if probableSpeech {

            speechFrameCount += 1
            silenceFrameCount = 0

            if !currentlySpeaking,
               speechFrameCount >= configuration.speechAttackFrames {

                currentlySpeaking = true
            }

        } else {

            speechFrameCount = 0
            silenceFrameCount += 1

            if currentlySpeaking,
               silenceFrameCount >= configuration.speechReleaseFrames {

                currentlySpeaking = false
            }

            if !currentlySpeaking {
                updateNoiseFloor(with: rms)
            }
        }

        return Result(
            isSpeech: currentlySpeaking,
            rms: rms,
            noiseFloor: noiseFloor,
            speechThreshold: threshold
        )
    }

    // MARK: - Reset

    func reset() {

        noiseFloor = configuration.initialNoiseFloor

        speechFrameCount = 0
        silenceFrameCount = 0

        currentlySpeaking = false
    }

    // MARK: - Threshold

    private var currentSpeechThreshold: Float {

        max(
            configuration.minimumSpeechThreshold,
            noiseFloor * configuration.noiseMultiplier
        )
    }

    // MARK: - Noise Floor

    private func updateNoiseFloor(
        with rms: Float
    ) {

        let rate = configuration.noiseFloorLearningRate

        noiseFloor =
            ((1 - rate) * noiseFloor)
            +
            (rate * rms)

        // Prevent pathological values.
        noiseFloor = max(
            0.0001,
            min(noiseFloor, 0.1)
        )
    }

    // MARK: - RMS

    private func calculateRMS(
        _ samples: [Float]
    ) -> Float {

        var sum: Float = 0

        for sample in samples {
            sum += sample * sample
        }

        let mean = sum / Float(samples.count)

        return sqrt(mean)
    }
}