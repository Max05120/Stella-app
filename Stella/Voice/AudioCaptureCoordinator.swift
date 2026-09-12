//
//  AudioCaptureCoordinator.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


import Foundation
@preconcurrency import AVFoundation

@MainActor
final class AudioCaptureCoordinator {

    enum Owner: String {
        case none
        case wakeWord
        case conversation
        case interruption
    }

    private(set) var owner: Owner = .none

    let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func claim(_ newOwner: Owner) {

        guard owner != newOwner else {
            return
        }

        print(
            "[AUDIO] owner \(owner.rawValue) → \(newOwner.rawValue)"
        )

        owner = newOwner
    }

    func release(_ currentOwner: Owner) {

        guard owner == currentOwner else {

            print(
                "[AUDIO] ignored release from \(currentOwner.rawValue); current owner is \(owner.rawValue)"
            )

            return
        }

        print(
            "[AUDIO] released \(currentOwner.rawValue)"
        )

        owner = .none
    }

    func isOwned(
        by expectedOwner: Owner
    ) -> Bool {

        owner == expectedOwner
    }
}