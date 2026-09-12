//
//  ConversationStateController.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  ConversationStateController.swift
//  Stella
//
//  Central owner of Stella's conversation-state transitions.
//
//  Architectural rule:
//
//  Audio components report events.
//  Speech components report events.
//  Backend components report events.
//
//  ONLY this controller decides whether a transition between
//  conversation states is valid.
//

import Foundation

final class ConversationStateController: @unchecked Sendable {

    // MARK: - Transition Event

    enum Event: Sendable {

        /// Stella's wake word was recognized.
        case wakeWordDetected

        /// Stella's greeting has completed.
        case greetingFinished

        /// TurnDetector produced a complete user utterance.
        case userTurnCompleted

        /// Whisper successfully produced a transcript.
        case transcriptionCompleted

        /// Backend / reasoning response became available.
        case responseReady

        /// Stella finished speaking normally.
        case speechFinished

        /// The user began speaking while Stella was speaking.
        case userInterrupted

        /// Interruption handling has completed and Stella
        /// should continue listening to the user's utterance.
        case interruptionHandled

        /// Conversation should return to standby.
        ///
        /// Later this can be triggered by phrases such as:
        ///
        /// "We're done here, Stella."
        /// "Go back to idle."
        /// "That's all."
        case endConversation

        /// Force-reset used for recovery from an unrecoverable
        /// voice-pipeline failure.
        case reset
    }

    // MARK: - Transition Result

    enum TransitionResult: Sendable {

        /// Event caused a legitimate state change.
        case transitioned(
            from: ConversationState,
            to: ConversationState
        )

        /// Event was valid but intentionally caused no change.
        case unchanged(
            state: ConversationState
        )

        /// Event is illegal from the current state.
        case rejected(
            state: ConversationState,
            event: Event
        )
    }

    // MARK: - State

    private let lock = NSLock()

    private var storedState: ConversationState

    // MARK: - Observers

    typealias StateObserver = (
        ConversationState,
        ConversationState
    ) -> Void

    private var observers: [UUID: StateObserver] = [:]

    // MARK: - Init

    init(
        initialState: ConversationState = .standby
    ) {

        self.storedState = initialState
    }

    // MARK: - Current State

    var state: ConversationState {

        lock.lock()
        defer { lock.unlock() }

        return storedState
    }

    // MARK: - Observers

    @discardableResult
    func addObserver(
        _ observer: @escaping StateObserver
    ) -> UUID {

        let id = UUID()

        lock.lock()
        observers[id] = observer
        lock.unlock()

        return id
    }

    func removeObserver(
        _ id: UUID
    ) {

        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: - Handle Event

    @discardableResult
    func handle(
        _ event: Event
    ) -> TransitionResult {

        lock.lock()

        let currentState = storedState

        let nextState = resolveTransition(
            from: currentState,
            event: event
        )

        guard let nextState else {

            lock.unlock()

            print(
                "[STATE] rejected \(event) while \(currentState.rawValue)"
            )

            return .rejected(
                state: currentState,
                event: event
            )
        }

        guard nextState != currentState else {

            lock.unlock()

            return .unchanged(
                state: currentState
            )
        }

        storedState = nextState

        let currentObservers = Array(
            observers.values
        )

        lock.unlock()

        print(
            "[STATE] \(currentState.rawValue) -> \(nextState.rawValue)"
        )

        for observer in currentObservers {

            observer(
                currentState,
                nextState
            )
        }

        return .transitioned(
            from: currentState,
            to: nextState
        )
    }

    // MARK: - Transition Rules

    private func resolveTransition(
        from state: ConversationState,
        event: Event
    ) -> ConversationState? {

        // Reset is always legal.
        if case .reset = event {
            return .standby
        }

        // Ending the conversation is always legal.
        if case .endConversation = event {
            return .standby
        }

        switch state {

        // MARK: Standby

        case .standby:

            switch event {

            case .wakeWordDetected:
                return .greeting

            default:
                return nil
            }

        // MARK: Greeting

        case .greeting:

            switch event {

            case .greetingFinished:
                return .listening

            default:
                return nil
            }

        // MARK: Listening

        case .listening:

            switch event {

            case .userTurnCompleted:
                return .transcribing

            default:
                return nil
            }

        // MARK: Transcribing

        case .transcribing:

            switch event {

            case .transcriptionCompleted:
                return .thinking

            default:
                return nil
            }

        // MARK: Thinking

        case .thinking:

            switch event {

            case .responseReady:
                return .speaking

            default:
                return nil
            }

        // MARK: Speaking

        case .speaking:

            switch event {

            case .speechFinished:
                return .listening

            case .userInterrupted:
                return .interrupted

            default:
                return nil
            }

        // MARK: Interrupted

        case .interrupted:

            switch event {

            case .interruptionHandled:
                return .listening

            default:
                return nil
            }
        }
    }

    // MARK: - Debug

    func debugPrintState() {

        print(
            "[STATE] current = \(state.rawValue)"
        )
    }
}