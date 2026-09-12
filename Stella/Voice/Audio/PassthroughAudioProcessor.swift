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

    func processCapture(_ samples: [Float]) -> [Float] {
        samples
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