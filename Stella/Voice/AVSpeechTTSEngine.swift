//
//  AVSpeechTTSEngine.swift
//  Stella
//
//  Created by Harish Maheshwaran on 31/08/26.
//


@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AVSpeechTTSEngine:
    NSObject,
    TTSEngine
{
    let name = "AVSpeech"

    private(set)
    var isSpeaking = false

    private let synthesizer =
        AVSpeechSynthesizer()

    private let audioEngine =
        AVAudioEngine()

    private let playerNode =
        AVAudioPlayerNode()

    private let spectrumAnalyzer =
        AudioSpectrumAnalyzer()

    private var spectrumCallback:
        ((AudioSpectrum) -> Void)?

    private var completion:
        (() -> Void)?

    override init() {
        super.init()

        audioEngine.attach(
            playerNode
        )
    }

    func prepare() async throws {
        // Nothing heavy to preload.
    }

    func speak(
        _ text: String,
        onSpectrum:
            @escaping (AudioSpectrum) -> Void,
        onFinished:
            @escaping () -> Void
    ) {
        spectrumCallback =
            onSpectrum

        completion =
            onFinished

        // Keep the existing AVSpeech PCM
        // implementation here.
    }

    func stop() {
        synthesizer.stopSpeaking(
            at: .immediate
        )

        playerNode.stop()

        spectrumAnalyzer?
            .reset()

        spectrumCallback?(.zero)

        spectrumCallback = nil

        completion = nil

        isSpeaking = false
    }
}