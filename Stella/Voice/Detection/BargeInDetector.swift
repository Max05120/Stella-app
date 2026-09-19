import Foundation

final class BargeInDetector {

    private let vad = VoiceActivityDetector()

    // Capture frames are ~10 ms.
    //
    // Keep the most recent 100 ms of speech decisions.
    private let voteWindowSize = 10

    // 7 speech-positive frames out of the last 10
    // are required for confirmation.
    //
    // They do NOT need to be consecutive.
    private let requiredSpeechVotes = 7

    private var speechVotes: [Bool] = []

    private var triggered = false

    private var playbackNoiseFloor: Float = 0
    private var calibrationFrames = 0

    func calibrate(
        frame: AudioCaptureEngine.CaptureFrame
    ) {

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

        let residualGate =
            max(
                result.speechThreshold,
                playbackNoiseFloor * 1.8
            )

        let likelyUserSpeech =
            result.isSpeech &&
            result.rms > residualGate

        // ----------------------------------------
        // Rolling 100 ms speech-vote window
        // ----------------------------------------

        speechVotes.append(
            likelyUserSpeech
        )

        if speechVotes.count >
            voteWindowSize
        {
            speechVotes.removeFirst(
                speechVotes.count -
                voteWindowSize
            )
        }

        // Do not make a decision until we have
        // accumulated the full 100 ms window.
        guard speechVotes.count ==
                voteWindowSize
        else {
            updatePlaybackNoiseFloor(
                rms: result.rms,
                likelyUserSpeech:
                    likelyUserSpeech
            )

            return false
        }

        let speechVoteCount =
            speechVotes.reduce(0) {
                partialResult,
                isSpeech in

                partialResult +
                    (isSpeech ? 1 : 0)
            }

        // ----------------------------------------
        // Diagnostic candidate
        // ----------------------------------------

        if speechVoteCount >=
            requiredSpeechVotes
        {
            triggered = true

            print(
                "[BARGE-VOTE] confirmed " +
                "votes=\(speechVoteCount)/\(voteWindowSize) " +
                "rms=\(result.rms) " +
                "gate=\(residualGate) " +
                "baseline=\(playbackNoiseFloor)"
            )

            return true
        }

        updatePlaybackNoiseFloor(
            rms: result.rms,
            likelyUserSpeech:
                likelyUserSpeech
        )

        return false
    }

    private func updatePlaybackNoiseFloor(
        rms: Float,
        likelyUserSpeech: Bool
    ) {

        // Don't aggressively teach possible speech
        // into Stella's playback residual baseline.
        //
        // Only slowly adapt when the current frame
        // is NOT considered speech-like.
        guard !likelyUserSpeech else {
            return
        }

        playbackNoiseFloor =
            (playbackNoiseFloor * 0.98)
            +
            (rms * 0.02)
    }

    func reset() {

        speechVotes.removeAll(
            keepingCapacity: true
        )

        triggered = false

        playbackNoiseFloor = 0
        calibrationFrames = 0

        vad.reset()
    }
}
