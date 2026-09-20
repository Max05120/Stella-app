//
//  AudioPreprocessor.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  AudioPreprocessor.swift
//  Stella
//
//  Foundation layer for Stella's audio preprocessing pipeline.
//
//  Capture path:
//      Microphone -> AudioCaptureEngine -> AudioPreprocessor
//
//  Render path:
//      Kokoro/TTS -> AudioPreprocessor
//
//  The render path is intentionally present from the beginning so that
//  WebRTC AEC3 can later receive Stella's own playback audio as the
//  echo-cancellation reference.
//

import Foundation

protocol AudioPreprocessor: AnyObject {

    /// Processes microphone audio before it is consumed by
    /// VAD, turn detection, Whisper, wake-word detection, etc.
    ///
    /// Returns the processed audio broken into its true ~10 ms
    /// sub-frames, each paired with the AEC metrics computed from
    /// that exact sub-frame — so any consumer that needs both the
    /// audio and its acoustic context (BargeInDetector) always sees
    /// them in sync. Callers that only want the flat processed
    /// signal (recording, Whisper, turn detection) can concatenate
    /// `.samples` across the returned frames.
    ///
    /// WebRTCAudioProcessor performs AEC3, noise suppression, and
    /// optionally gain control here.
    func processCapture(_ samples: [Float]) -> [AECProcessedFrame]

    /// Supplies Stella's outgoing playback audio to the processor.
    ///
    /// The passthrough processor ignores this for now.
    /// WebRTC AEC3 will later use it as the render/reference stream.
    func processRender(_ samples: [Float])

    /// Clears any internal processor state.
    func reset()
}

extension AudioPreprocessor {

    func reset() {
        // Default no-op.
    }
}
