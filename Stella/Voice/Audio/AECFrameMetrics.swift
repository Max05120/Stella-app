//
//  AECFrameMetrics.swift
//  Stella
//
//  Created by Harish Maheshwaran on 20/09/26.
//


//
//  AECFrameMetrics.swift
//  Stella
//
//  Synchronized per-frame acoustic / AEC metadata.
//
//  Background:
//
//  BargeInDetector used to run VAD on one chunk of microphone audio,
//  then separately fetch AEC diagnostics (suppression, correlation,
//  render envelope) via WebRTCAudioProcessor.currentBargeDiagnostics()
//  moments later, on a different call, from a different tap
//  invocation. The two were never guaranteed to describe the same
//  10 ms of sound — a real risk when trying to correlate "was this
//  speech" with "did this survive AEC" frame by frame.
//
//  AECFrameMetrics/AECProcessedFrame exist to make that impossible:
//  the metrics are computed inline, in the same loop iteration, from
//  the exact same samples that get returned alongside them.
//

import Foundation

/// Synchronized AEC/acoustic measurements for one true ~10 ms
/// capture frame.
struct AECFrameMetrics: Sendable {

    /// RMS of the microphone signal BEFORE AEC3 processing.
    let rawRMS: Float

    /// RMS of the same 10 ms window AFTER AEC3 processing.
    let processedRMS: Float

    /// Most recent Kokoro/render RMS at the moment this exact
    /// capture frame was processed.
    ///
    /// Render and capture arrive on separate callbacks, so this is
    /// the closest available value rather than a guaranteed
    /// same-instant sample — acceptable because render envelope is
    /// only ever used as corroborating context, never as a
    /// standalone gate (see BargeInDetector).
    let renderRMS: Float

    /// Rolling ~250 ms envelope of Stella's own playback activity,
    /// sampled at the same moment as the fields above.
    let renderEnvelope: Float

    /// Best-lag normalized correlation between recent raw capture
    /// and Stella's render history, computed over a rolling 100 ms
    /// capture window and refreshed every ~10 ms.
    let correlation: Float

    /// Lag, in milliseconds, at which the best correlation above was
    /// found.
    let correlationLagMs: Int

    /// processedRMS / rawRMS.
    ///
    /// Near 0 → AEC removed most of the signal (echo-like).
    /// Near 1 → the signal largely survived AEC (near-end-speech-like).
    ///
    /// NOT reliable as a standalone gate: real double-talk has been
    /// observed producing suppression as low as ~0.15, so a low
    /// value here must never disqualify a frame on its own.
    var suppressionRatio: Float {
        processedRMS / max(rawRMS, 0.0001)
    }
}

/// A short slice of AEC-processed capture audio paired with the
/// metrics computed from those exact same samples.
struct AECProcessedFrame: Sendable {
    let samples: [Float]
    let metrics: AECFrameMetrics
}