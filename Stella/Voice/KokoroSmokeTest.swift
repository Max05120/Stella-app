import AVFoundation
import Foundation
import Kokoro

@MainActor
enum KokoroFinalVoiceBakeoff {

    private static var player: AVAudioPlayer?

    private static let voices = [
        "af_heart",
        "af_bella"
    ]

    private static let prompts = [
        """
        Yeah, absolutely. I can do that.
        """,

        """
        I found a few options. The second one looks like the best fit because it gives you the strongest balance between speed, quality, and simplicity.
        """,

        """
        Here’s what I found. The main issue isn’t really the model itself, it’s the delay before the first piece of audio starts playing. If we generate the entire response before playback begins, even a fast model can feel slow. The better approach is to generate Stella’s reply in short chunks and start playing the first chunk immediately while the rest continues processing.
        """
    ]

    static func run() async {
        print("[KOKORO] final voice bake-off starting")

        do {
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

            print("[KOKORO] loading model...")

            let loadStart =
                CFAbsoluteTimeGetCurrent()

            let model =
                try KModel(
                    configURL: configURL,
                    weightsURL: weightsURL
                )

            let voiceLoader =
                VoiceLoader(
                    baseDirectory: voicesDirectory,
                    enableDownload: false
                )

            let pipeline =
                KPipeline(
                    model: model,
                    voices: voiceLoader,
                    sampleRate: 24_000,
                    langCode: "en-us"
                )

            let loadTime =
                CFAbsoluteTimeGetCurrent()
                - loadStart

            print(
                String(
                    format:
                        "[KOKORO] model loaded in %.3fs",
                    loadTime
                )
            )

            // Warm-up pass so Heart doesn't get penalized
            // for being the first inference.
            print("[KOKORO] warming up model...")

            _ = try pipeline.synthesize(
                text: "Hey.",
                voice: "af_heart",
                speed: 1.0
            )

            print("[KOKORO] warm-up complete")

            for voice in voices {

                print("")
                print("==============================")
                print("[KOKORO] VOICE: \(voice)")
                print("==============================")

                _ = try voiceLoader.loadVoice(
                    named: voice
                )

                for (index, prompt) in prompts.enumerated() {

                    print("")
                    print(
                        "[KOKORO] \(voice) prompt \(index + 1)"
                    )

                    let start =
                        CFAbsoluteTimeGetCurrent()

                    let result =
                        try pipeline.synthesize(
                            text: prompt,
                            voice: voice,
                            speed: 1.0
                        )

                    let synthTime =
                        CFAbsoluteTimeGetCurrent()
                        - start

                    let audioDuration =
                        Double(result.audio.count)
                        /
                        Double(result.sampleRate)

                    let rtf =
                        synthTime
                        /
                        max(
                            audioDuration,
                            0.001
                        )

                    print(
                        String(
                            format:
                                "[KOKORO] synth %.3fs | audio %.3fs | RTF %.3f",
                            synthTime,
                            audioDuration,
                            rtf
                        )
                    )

                    let filename =
                        "stella-\(voice)-\(index + 1).wav"

                    let outputURL =
                        FileManager.default
                            .temporaryDirectory
                            .appendingPathComponent(
                                filename
                            )

                    try? FileManager.default
                        .removeItem(
                            at: outputURL
                        )

                    try writeWAV(
                        samples: result.audio,
                        sampleRate: result.sampleRate,
                        to: outputURL
                    )

                    print(
                        "[KOKORO] 🔊 playing \(voice) prompt \(index + 1)"
                    )

                    try await playAndWait(
                        url: outputURL
                    )

                    try? await Task.sleep(
                        for: .milliseconds(800)
                    )
                }
            }

            print("")
            print("[KOKORO] ✅ final bake-off complete")

        } catch {
            print(
                "[KOKORO] ❌ error:",
                error.localizedDescription
            )

            print(
                "[KOKORO] raw:",
                error
            )
        }
    }

    private static func playAndWait(
        url: URL
    ) async throws {

        let newPlayer =
            try AVAudioPlayer(
                contentsOf: url
            )

        player = newPlayer

        newPlayer.prepareToPlay()

        guard newPlayer.play() else {
            throw NSError(
                domain: "KokoroFinalBakeoff",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Playback failed"
                ]
            )
        }

        while newPlayer.isPlaying {
            try await Task.sleep(
                for: .milliseconds(100)
            )
        }

        player = nil
    }

    private static func writeWAV(
        samples: [Float],
        sampleRate: Int,
        to url: URL
    ) throws {

        guard
            let format =
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(sampleRate),
                    channels: 1,
                    interleaved: false
                )
        else {
            throw NSError(
                domain: "KokoroFinalBakeoff",
                code: 2
            )
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
            throw NSError(
                domain: "KokoroFinalBakeoff",
                code: 3
            )
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

        let file =
            try AVAudioFile(
                forWriting: url,
                settings: format.settings
            )

        try file.write(
            from: buffer
        )
    }
}
