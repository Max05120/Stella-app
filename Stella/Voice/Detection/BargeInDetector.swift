import Foundation

/// Experimental barge-in candidate detector.
///
/// Requires sustained accepted clean-capture audio over a
/// 200 ms window. The current VoiceActivityDetector uses adaptive
/// energy and hysteresis; it does not establish speaker identity
/// or independently distinguish speech from residual echo.
///
/// Suppression and render correlation are logged for diagnosis,
/// but do not contribute to confirmation.
///
/// Keep observe-only enabled pending acoustic validation.

final class BargeInDetector {

    // MARK: - Result

    /// Per-sub-frame evidence breakdown, returned so callers can log
    /// the exact synchronized signals a decision was based on.
    struct EvidenceBreakdown: Sendable {
        let isSpeechVAD: Bool
        let rms: Float
        let residualGate: Float
        let suppressionRatio: Float
        let correlation: Float
        let frameEvidence: Float
        let windowEvidence: Float
        let framesInWindow: Int
        let speechGateFramesInWindow: Int
    }

    struct Decision: Sendable {
        let triggered: Bool
        let evidence: EvidenceBreakdown
    }

    private let vad = VoiceActivityDetector()

    // MARK: - Configuration
    //
    // Starting values only — see the class doc comment above.

    /// Sub-frames of rolling evidence to accumulate before deciding.
    /// At ~10 ms/frame this is a 100 ms decision window.
    private let evidenceWindowSize = 20

    /// Summed evidence across the window required to confirm a
    /// barge-in. Each frame can contribute at most ~2.0 (1.0 from
    /// the VAD gate, up to 0.6 from suppression, up to 0.4 from
    /// correlation), so this requires sustained, corroborated
    /// evidence rather than one strong frame.
    let requiredWindowEvidence: Float = 16.0

    /// Regardless of accumulated evidence, at least this many
    /// sub-frames in the window must have passed the raw VAD speech
    /// gate. This exists specifically to reject short transients (a
    /// water-bottle tap, a keyboard click, a chair creak) that can
    /// momentarily score well on suppression/correlation without any
    /// sustained speech-like energy pattern — exactly the failure
    /// mode observed in this project's own logs.
    private let minimumSpeechGateFrames = 16

    /// Multiplier applied to the learned playback-residual floor to
    /// get the VAD's speech threshold while Stella is talking.
    private let residualGateMultiplier: Float = 1.8

    /// Weight given to "this frame survived AEC" (suppression ratio
    /// near 1). Capped well below the VAD gate's own weight — real
    /// double-talk has been observed surviving AEC as poorly as
    /// ~0.15 suppression, so a LOW suppression ratio must never be
    /// treated as disqualifying, only as slightly less corroborating.
//    private let suppressionWeight: Float = 0.6

    /// Weight given to "this frame's raw capture looks unlike
    /// Stella's own recent render" (low correlation). Same caveat as
    /// above — correlation has also been observed to flip on real
    /// speech, so this only nudges the score, never gates it.
//    private let correlationWeight: Float = 0.4

    // MARK: - State

    private var evidenceWindow: [Float] = []
    private var speechGateWindow: [Bool] = []

    private var triggered = false

    private var playbackNoiseFloor: Float = 0
    private var calibrationFrames = 0

    // MARK: - Calibration

    /// Called for ~350 ms right after Stella's playback actually
    /// starts, before the detector is armed, to learn her typical
    /// residual level under the current room/output-volume
    /// conditions.
    func calibrate(
        frame: AudioCaptureEngine.CaptureFrame
    ) {
        for subFrame in frame.subFrames {
            calibrate(subFrame: subFrame)
        }
    }

    private func calibrate(
        subFrame: AECProcessedFrame
    ) {
        let result = vad.process(
            samples: subFrame.samples
        )

        if calibrationFrames == 0 {

            playbackNoiseFloor = max(
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

    // MARK: - Process

    /// Feeds one capture frame — possibly containing several true
    /// ~10 ms AEC sub-frames — through the classifier.
    ///
    /// Returns one `Decision` per sub-frame actually evaluated, each
    /// carrying the exact synchronized evidence behind it, so the
    /// caller can log every sub-frame at whatever cadence it likes
    /// without ever re-fetching state separately. Processing for
    /// this call stops at the first confirmed trigger; once
    /// triggered, this returns an empty array until `reset()`.
    func process(
        frame: AudioCaptureEngine.CaptureFrame,
        observeOnly: Bool = false
    ) -> [Decision] {

        if triggered && !observeOnly {
            return []
        }

        var decisions: [Decision] = []

        for subFrame in frame.subFrames {
            let decision = process(subFrame: subFrame)
            decisions.append(decision)

            // Live mode latches at the first accepted interruption.
            // Observe-only mode evaluates every subsequent sub-frame.
            if decision.triggered && !observeOnly {
                triggered = true
                break
            }
        }

        return decisions
    }

    private func process(
        subFrame: AECProcessedFrame
    ) -> Decision {

        let result = vad.process(
            samples: subFrame.samples
        )

        let residualGate = max(
            result.speechThreshold,
            playbackNoiseFloor * residualGateMultiplier
        )

        let passesSpeechGate =
            result.isSpeech &&
            result.rms > residualGate

        // ------------------------------------------------
        // Per-frame weighted evidence.
        //
        // The VAD gate is the base signal — without it, nothing
        // else matters, matching this project's own finding that
        // high energy alone (a water bottle, a chair) is not
        // speech. Suppression and correlation only ADD corroborating
        // weight on top of a frame that already looks speech-like.
        // ------------------------------------------------

        // Count accepted audio duration.
        // Suppression and asynchronous correlation remain diagnostics;
        // neither contributes an unvalidated confidence bonus.
        let frameEvidence: Float = passesSpeechGate ? 1.0 : 0.0

        evidenceWindow.append(frameEvidence)
        speechGateWindow.append(passesSpeechGate)

        if evidenceWindow.count > evidenceWindowSize {
            evidenceWindow.removeFirst(
                evidenceWindow.count - evidenceWindowSize
            )
        }

        if speechGateWindow.count > evidenceWindowSize {
            speechGateWindow.removeFirst(
                speechGateWindow.count - evidenceWindowSize
            )
        }

        let windowEvidence = evidenceWindow.reduce(0, +)

        let speechGateFrames = speechGateWindow.reduce(0) {
            partialResult, passed in

            partialResult + (passed ? 1 : 0)
        }

        let breakdown = EvidenceBreakdown(
            isSpeechVAD: passesSpeechGate,
            rms: result.rms,
            residualGate: residualGate,
            suppressionRatio: subFrame.metrics.suppressionRatio,
            correlation: subFrame.metrics.correlation,
            frameEvidence: frameEvidence,
            windowEvidence: windowEvidence,
            framesInWindow: evidenceWindow.count,
            speechGateFramesInWindow: speechGateFrames
        )

        // Don't make a decision until the full window has filled.
        guard evidenceWindow.count == evidenceWindowSize else {

            updatePlaybackNoiseFloor(
                rms: result.rms,
                passesSpeechGate: passesSpeechGate
            )

            return Decision(
                triggered: false,
                evidence: breakdown
            )
        }

        let confirmed =
            passesSpeechGate &&
            windowEvidence >= requiredWindowEvidence &&
            speechGateFrames >= minimumSpeechGateFrames

        if confirmed {
            return Decision(
                triggered: true,
                evidence: breakdown
            )
        }

        updatePlaybackNoiseFloor(
            rms: result.rms,
            passesSpeechGate: passesSpeechGate
        )

        return Decision(
            triggered: false,
            evidence: breakdown
        )
    }

    private func updatePlaybackNoiseFloor(
        rms: Float,
        passesSpeechGate: Bool
    ) {

        // Don't teach possible speech into Stella's playback
        // residual baseline. Only slowly adapt when the current
        // frame is NOT considered speech-like.
        guard !passesSpeechGate else {
            return
        }

        playbackNoiseFloor =
            (playbackNoiseFloor * 0.98)
            +
            (rms * 0.02)
    }

    // MARK: - Reset

    func reset() {

        evidenceWindow.removeAll(
            keepingCapacity: true
        )

        speechGateWindow.removeAll(
            keepingCapacity: true
        )

        triggered = false

        playbackNoiseFloor = 0
        calibrationFrames = 0

        vad.reset()
    }
}
