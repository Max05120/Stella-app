//
//  VoiceDetectionSmokeTest.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  VoiceDetectionSmokeTest.swift
//  Stella
//
//  Temporary test harness for the new audio capture + turn detection
//  architecture.
//
//  This is NOT part of Stella's final conversation pipeline.
//

import Foundation

final class VoiceDetectionSmokeTest {

    private let audioCaptureEngine: AudioCaptureEngine
    private let turnDetector: TurnDetector

    private var listenerID: UUID?

    init() {

        let processor = PassthroughAudioProcessor()

        self.audioCaptureEngine = AudioCaptureEngine(
            preprocessor: processor
        )

        self.turnDetector = TurnDetector()
    }

    func start() {

        guard listenerID == nil else {
            print("[VOICE TEST] already running")
            return
        }

        listenerID = audioCaptureEngine.addListener {
            [weak self] frame in

            self?.process(frame)
        }

        do {

            try audioCaptureEngine.start()

            print("[VOICE TEST] started")
            print("[VOICE TEST] speak naturally")
            print("[VOICE TEST] try pausing for about 1 second mid-sentence")

        } catch {

            print(
                "[VOICE TEST] failed to start:",
                error.localizedDescription
            )

            if let listenerID {
                audioCaptureEngine.removeListener(listenerID)
            }

            listenerID = nil
        }
    }

    func stop() {

        if let listenerID {
            audioCaptureEngine.removeListener(listenerID)
        }

        listenerID = nil

        audioCaptureEngine.stop()
        turnDetector.reset()

        print("[VOICE TEST] stopped")
    }

    private func process(
        _ frame: AudioCaptureEngine.CaptureFrame
    ) {

        guard let event = turnDetector.process(
            frame: frame
        ) else {
            return
        }

        switch event {

        case .speechStarted:

            print("[TURN] speech started")

        case .speechEnded(let utterance):

            print(
                String(
                    format: "[TURN] speech ended — %.2fs — %d samples",
                    utterance.duration,
                    utterance.samples.count
                )
            )
        }
    }
}