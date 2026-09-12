//
//  ConversationState.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  ConversationState.swift
//  Stella
//
//  Defines Stella's voice conversation states.
//
//  Important:
//  This file contains state definitions only.
//  It does not perform audio capture, transcription,
//  backend requests, or TTS.
//

import Foundation

enum ConversationState: String, Sendable {

    /// Stella is dormant and waiting for the wake word.
    case standby

    /// Stella has just been awakened and is delivering
    /// or preparing the greeting response.
    case greeting

    /// Stella is actively waiting for the user's speech.
    case listening

    /// A complete user utterance has been captured
    /// and is being converted to text.
    case transcribing

    /// Stella has a transcript and is waiting for
    /// the backend / reasoning response.
    case thinking

    /// Stella is currently speaking a response.
    case speaking

    /// The user started speaking while Stella was speaking.
    ///
    /// This will become important when WebRTC AEC3
    /// and natural barge-in are added.
    case interrupted
}