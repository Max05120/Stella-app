//
//  ConversationStateSmokeTest.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  ConversationStateSmokeTest.swift
//  Stella
//
//  Temporary state-machine test.
//

import Foundation

final class ConversationStateSmokeTest {

    private let controller =
        ConversationStateController()
    let webRTC = WebRTCAudioProcessor()

    func run() {

        print("")
        print("==============================")
        print("CONVERSATION STATE SMOKE TEST")
        print("==============================")
        print("[WEBRTC TEST] ready =", webRTC.isReady)
        webRTC.debugCaptureSmokeTest()

        controller.debugPrintState()

        controller.handle(
            .wakeWordDetected
        )

        controller.handle(
            .greetingFinished
        )

        controller.handle(
            .userTurnCompleted
        )

        controller.handle(
            .transcriptionCompleted
        )

        controller.handle(
            .responseReady
        )

        controller.handle(
            .speechFinished
        )

        print("")
        print("--- INTERRUPTION TEST ---")

        controller.handle(
            .userTurnCompleted
        )

        controller.handle(
            .transcriptionCompleted
        )

        controller.handle(
            .responseReady
        )

        controller.handle(
            .userInterrupted
        )

        controller.handle(
            .interruptionHandled
        )
        
        let renderTestSamples =
            Array(
                repeating: Float(0),
                count: 240
            )

        webRTC.processRender(
            renderTestSamples
        )

        print("")
        print("--- END CONVERSATION ---")

        controller.handle(
            .endConversation
        )

        controller.debugPrintState()

        print("")
        print("--- INVALID EVENT TEST ---")

        controller.handle(
            .speechFinished
        )

        print("==============================")
        print("")
    }
}
