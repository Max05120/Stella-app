import Foundation

final class BargeInDetector {

    private let vad = VoiceActivityDetector()

    private let requiredSpeechFrames: Int

    private var consecutiveSpeechFrames = 0
    private var triggered = false

    // Residual echo baseline measured while Stella speaks.
    private var playbackNoiseFloor: Float = 0
    private var calibrationFrames = 0

    init(
        requiredSpeechFrames: Int = 6
    ) {
        self.requiredSpeechFrames =
            requiredSpeechFrames
    }

    /// Call while Stella is speaking but barge-in is not armed yet.
    func calibrate(
        frame: AudioCaptureEngine.CaptureFrame
    ) {

        guard !frame.samples.isEmpty else {
            return
        }

        let result =
            vad.process(
                samples: frame.samples
            )

        if calibrationFrames == 0 {

            playbackNoiseFloor =
                max(
                    result.rms,
                    result.noiseFloor
                )

        } else {

            // Slowly follow the residual playback level.
            playbackNoiseFloor =
                (playbackNoiseFloor * 0.90)
                +
                (result.rms * 0.10)
        }

        calibrationFrames += 1
    }

    func process(
        frame: AudioCaptureEngine.CaptureFrame
    ) -> Bool {

        guard !triggered else {
            return false
        }

        let result =
            vad.process(
                samples: frame.samples
            )

        // Important:
        // VAD speech alone is not enough while Stella is playing.
        //
        // The signal also has to rise meaningfully above the
        // AEC residual level we measured during playback.
        let residualGate =
            max(
                result.speechThreshold,
                playbackNoiseFloor * 1.8
            )

        let likelyUserSpeech =
            result.isSpeech
            &&
            result.rms > residualGate

        if likelyUserSpeech {

            consecutiveSpeechFrames += 1

            if consecutiveSpeechFrames >=
                requiredSpeechFrames
            {
                triggered = true

                print(
                    "[BARGE] confirmed "
                    + "rms=\(result.rms) "
                    + "gate=\(residualGate) "
                    + "baseline=\(playbackNoiseFloor)"
                )

                return true
            }

        } else {

            consecutiveSpeechFrames = 0

            // Continue adapting slowly while we believe
            // this is only playback residual.
            playbackNoiseFloor =
                (playbackNoiseFloor * 0.98)
                +
                (result.rms * 0.02)
        }

        return false
    }

    func reset() {

        consecutiveSpeechFrames = 0
        triggered = false

        playbackNoiseFloor = 0
        calibrationFrames = 0

        vad.reset()
    }
}
