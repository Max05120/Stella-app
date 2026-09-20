//
//  PassthroughAudioProcessor.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  PassthroughAudioProcessor.swift
//  Stella
//
//  Initial AudioPreprocessor implementation.
//
//  It intentionally performs no DSP.
//  Its purpose is to establish the processing boundary before
//  WebRTC APM/AEC3 is integrated.
//

import Foundation

final class PassthroughAudioProcessor: AudioPreprocessor {

    func processCapture(_ samples: [Float]) -> [AECProcessedFrame] {
        guard !samples.isEmpty else {
            return []
        }

        // No AEC runs on the passthrough path, so there is nothing
        // meaningful to report for render/suppression/correlation.
        // Metrics are zeroed rather than made optional so every
        // consumer can rely on a single, non-optional shape.
        let metrics = AECFrameMetrics(
            rawRMS: 0,
            processedRMS: 0,
            renderRMS: 0,
            renderEnvelope: 0,
            correlation: 0,
            correlationLagMs: 0
        )

        return [
            AECProcessedFrame(
                samples: samples,
                metrics: metrics
            )
        ]
    }

    func processRender(_ samples: [Float]) {
        // Intentionally ignored for now.
        //
        // WebRTCAudioProcessor will eventually consume this stream
        // as the AEC3 render/reference signal.
    }

    func reset() {
        // No internal state to clear.
    }
}
