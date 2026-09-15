//
//  KokoroSynthesisWorker.swift
//  Stella
//
//  Created by Harish Maheshwaran on 13/09/26.
//


import Foundation
import Kokoro

actor KokoroSynthesisWorker {

    struct AudioResult: Sendable {
        let audio: [Float]
        let sampleRate: Int
    }

    private var pipeline: KPipeline?

    private let voice = "af_heart"
    private let sampleRate = 24_000

    func prepare(
        configURL: URL,
        weightsURL: URL,
        voicesDirectory: URL
    ) throws {

        guard pipeline == nil else {
            return
        }

        let model = try KModel(
            configURL: configURL,
            weightsURL: weightsURL
        )

        let voices = VoiceLoader(
            baseDirectory: voicesDirectory,
            enableDownload: false
        )

        _ = try voices.loadVoice(
            named: voice
        )

        pipeline = KPipeline(
            model: model,
            voices: voices,
            sampleRate: sampleRate,
            langCode: "en-us"
        )
    }

    func synthesize(
        text: String,
        speed: Float
    ) throws -> AudioResult {

        guard let pipeline else {
            throw NSError(
                domain: "Stella.Kokoro",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Kokoro synthesis worker is not prepared."
                ]
            )
        }

        let result = try pipeline.synthesize(
            text: text,
            voice: voice,
            speed: speed
        )

        return AudioResult(
            audio: result.audio,
            sampleRate: result.sampleRate
        )
    }
}