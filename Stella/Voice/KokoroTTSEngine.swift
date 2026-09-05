//
//  KokoroTTSEngine.swift
//  Stella
//
//  Created by Harish Maheshwaran on 31/08/26.
//


//
// KokoroTTSEngine.swift
// Stella
//

@preconcurrency import AVFoundation
import Foundation
import Kokoro

@MainActor
final class KokoroTTSEngine {

    private let sharedEngine: AVAudioEngine
    private let playerNode = AVAudioPlayerNode()
    private let analyzer = AudioSpectrumAnalyzer()

    private var pipeline: KPipeline?
    private var isPrepared = false
    private var isSpeaking = false

    private var pendingBuffers = 0
    private var synthesisTask: Task<Void, Never>?
    private var synthesisFinished = false

    var onSpectrum: ((AudioSpectrum) -> Void)?
    var onFinished: (() -> Void)?

    private let voice = "af_heart"
    private let sampleRate = 24_000

    init(sharedEngine: AVAudioEngine) {
        self.sharedEngine = sharedEngine
        sharedEngine.attach(playerNode)
    }

    // MARK: - Prepare

    func prepare() async throws {
        guard !isPrepared else {
            return
        }

        let appSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]

        let root =
            appSupport
                .appendingPathComponent("Stella")
                .appendingPathComponent("Kokoro")
                .appendingPathComponent("Kokoro-82M-Swift")

        let mlxDirectory =
            root.appendingPathComponent("MLX_GPU")

        let configURL =
            root.appendingPathComponent("config.json")

        let weightsURL =
            mlxDirectory.appendingPathComponent(
                "kokoro-v1_0.safetensors"
            )

        let voicesDirectory =
            mlxDirectory.appendingPathComponent("voices")

        print("[TTS] loading Kokoro...")

        let started = CFAbsoluteTimeGetCurrent()

        let model =
            try KModel(
                configURL: configURL,
                weightsURL: weightsURL
            )

        let voices =
            VoiceLoader(
                baseDirectory: voicesDirectory,
                enableDownload: false
            )

        _ = try voices.loadVoice(
            named: voice
        )

        pipeline =
            KPipeline(
                model: model,
                voices: voices,
                sampleRate: sampleRate,
                langCode: "en-us"
            )

        try configureAudioEngine()

        isPrepared = true

        let elapsed =
            CFAbsoluteTimeGetCurrent() - started

        print(
            String(
                format:
                    "[TTS] Kokoro ready in %.3fs",
                elapsed
            )
        )
    }

    // MARK: - Speak

    func speak(
        _ text: String,
        speed: Float = 1.04,
        
        onFinished: (() -> Void)? = nil
    )
        
    {
        guard
            isPrepared,
            let pipeline
        else {
            print("[TTS] Kokoro not prepared")
            onFinished?()
            return
        }

        stop()

        self.onFinished = onFinished
        isSpeaking = true
        
        synthesisFinished = false
        pendingBuffers = 0
        analyzer?.reset()
        
        let chunks =
            Self.makeSpeechChunks(
                from: text
            )

        print(
            "[TTS] Kokoro chunks:",
            chunks.count
        )

        synthesisTask = Task {
            [weak self] in

            guard let self else {
                return
            }

            for (index, chunk)
                in chunks.enumerated()
            {
                guard !Task.isCancelled else {
                    return
                }

                let started =
                    CFAbsoluteTimeGetCurrent()

                do {
                    let result =
                        try pipeline.synthesize(
                            text: chunk,
                            voice: self.voice,
                            speed: speed
                        )

                    let elapsed =
                        CFAbsoluteTimeGetCurrent()
                        - started

                    print(
                        String(
                            format:
                                "[TTS] chunk %d/%d generated in %.3fs",
                            index + 1,
                            chunks.count,
                            elapsed
                        )
                    )

                    guard !Task.isCancelled else {
                        return
                    }

                    try self.queue(
                        samples: Self.applyEdgeFades(result.audio),
                        sampleRate:
                            result.sampleRate
                    )

                } catch {
                    print(
                        "[TTS] Kokoro synthesis error:",
                        error.localizedDescription
                    )

                    self.finish()
                    return
                }
            }
            self.synthesisFinished = true
            self.finishIfPlaybackComplete()
        }
    }

    // MARK: - PCM queue

    private func queue(
        samples: [Float],
        sampleRate: Int
    ) throws {
        guard !samples.isEmpty else {
            return
        }

        guard
            let format =
                AVAudioFormat(
                    commonFormat:
                        .pcmFormatFloat32,
                    sampleRate:
                        Double(sampleRate),
                    channels: 1,
                    interleaved: false
                )
        else {
            return
        }

        let frameCount =
            AVAudioFrameCount(
                samples.count
            )

        guard
            let buffer =
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCount
                ),
            let channel =
                buffer.floatChannelData?[0]
        else {
            return
        }

        buffer.frameLength =
            frameCount

        samples.withUnsafeBufferPointer {
            source in

            guard
                let base =
                    source.baseAddress
            else {
                return
            }

            channel.update(
                from: base,
                count: samples.count
            )
        }

        pendingBuffers += 1

        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType:
                .dataPlayedBack
        ) {
            [weak self]
            _ in

            Task {
                @MainActor in

                guard let self else {
                    return
                }

                self.pendingBuffers =
                    max(
                        0,
                        self.pendingBuffers - 1
                    )

                self.finishIfPlaybackComplete()
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    // MARK: - Audio engine

    private func configureAudioEngine() throws {
        guard
            let format =
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(sampleRate),
                    channels: 1,
                    interleaved: false
                )
        else {
            return
        }

        sharedEngine.connect(
            playerNode,
            to: sharedEngine.mainMixerNode,
            format: format
        )

        installSpectrumTap(format: format)

        // No .prepare()/.start() here — MicrophoneRecorder owns
        // starting the shared engine.
    }

    private func installSpectrumTap(
        format: AVAudioFormat
    ) {
        let analyzer = self.analyzer

        playerNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) {
            [weak self]
            buffer,
            _ in

            guard
                buffer.frameLength > 0,
                let source =
                    buffer.floatChannelData?[0]
            else {
                return
            }

            let count =
                Int(buffer.frameLength)

            let samples =
                Array(
                    UnsafeBufferPointer(
                        start: source,
                        count: count
                    )
                )

            analyzer?.analyze(
                samples: samples,
                sampleRate:
                    Float(
                        buffer.format.sampleRate
                    )
            )

            let snapshot =
                analyzer?.snapshot()
                ?? .zero

            Task {
                @MainActor in

                self?
                    .onSpectrum?(
                        snapshot
                    )
            }
        }
    }

    // MARK: - Completion

    private func finishIfPlaybackComplete() {

        guard isSpeaking else {
            return
        }

        guard synthesisFinished else {
            return
        }

        guard pendingBuffers == 0 else {
            return
        }

        finish()
    }
    private func finish() {

        guard isSpeaking else {
            return
        }

        print("[TTS] Kokoro playback finished")

        isSpeaking = false
        synthesisFinished = false

        synthesisTask = nil

        analyzer?.reset()

        onSpectrum?(.zero)

        let callback =
            onFinished

        onFinished = nil

        callback?()
    }

    // MARK: - Stop

    func stop() {

        synthesisTask?.cancel()
        synthesisTask = nil

        playerNode.stop()

        pendingBuffers = 0
        synthesisFinished = false

        analyzer?.reset()

        onSpectrum?(.zero)

        isSpeaking = false

        onFinished = nil
    }
    // MARK: - Chunking

    private static func makeSpeechChunks(
        from text: String
    ) -> [String] {

        let cleaned =
            text
                .replacingOccurrences(
                    of: "\n",
                    with: " "
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        guard !cleaned.isEmpty else {
            return []
        }

        let separators =
            CharacterSet(
                charactersIn:
                    ".!?;:"
            )

        let words =
            cleaned.split(
                separator: " "
            )

        var chunks: [String] = []
        var current: [Substring] = []

        for word in words {

            current.append(word)

            let endsSentence =
                word.unicodeScalars
                    .last
                    .map {
                        separators.contains($0)
                    }
                    ?? false

            let targetReached =
                current.count >= 24

            let hardLimit =
                current.count >= 40

            if
                (endsSentence &&
                 current.count >= 5)
                ||
                targetReached
                ||
                hardLimit
            {
                chunks.append(
                    current
                        .joined(
                            separator: " "
                        )
                )

                current.removeAll(
                    keepingCapacity: true
                )
            }
        }

        if !current.isEmpty {
            chunks.append(
                current.joined(
                    separator: " "
                )
            )
        }

        return chunks
    }
    
    private static func applyEdgeFades(_ samples: [Float]) -> [Float] {
        let crossfadeSamples = 240 // ~10ms at 24kHz
        guard samples.count > crossfadeSamples * 2 else { return samples }
        var out = samples
        for i in 0..<crossfadeSamples {
            let t = Float(i) / Float(crossfadeSamples)
            out[i] *= t
            out[out.count - 1 - i] *= t
        }
        return out
    }
}
