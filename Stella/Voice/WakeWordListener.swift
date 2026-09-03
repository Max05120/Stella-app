//
//  WakeWordListener.swift
//  Stella
//
//  Created by Harish Maheshwaran on 02/09/26.
//


import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class WakeWordListener: ObservableObject {

    @Published private(set) var isListening = false
    @Published private(set) var lastHeardText = ""
    
    var onWakeWordDetected: (() -> Void)?
    private var hasTriggeredWake = false

    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private let speechRecognizer =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private let wakePhrases = [
        "stella",
        "hey stella"
    ]


    // MARK: - Permissions

    func requestPermissions() async -> Bool {

        let speechAllowed: Bool = await withCheckedContinuation {
            continuation in

            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(
                    returning: status == .authorized
                )
            }
        }

        guard speechAllowed else {
            print("[WAKE] speech recognition permission denied")
            return false
        }

        let microphoneAllowed =
            await AVCaptureDevice.requestAccess(
                for: .audio
            )

        guard microphoneAllowed else {
            print("[WAKE] microphone permission denied")
            return false
        }

        return true
    }


    // MARK: - Start

    func start() {

        guard !isListening else {
            return
        }
        
        hasTriggeredWake = false

        guard let speechRecognizer else {
            print("[WAKE] speech recognizer unavailable")
            return
        }

        guard speechRecognizer.isAvailable else {
            print("[WAKE] speech recognizer currently unavailable")
            return
        }

        stop()

        let request =
            SFSpeechAudioBufferRecognitionRequest()

        request.shouldReportPartialResults = true

        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request

        let inputNode =
            audioEngine.inputNode

        let recordingFormat =
            inputNode.outputFormat(
                forBus: 0
            )

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: recordingFormat
        ) {
            [weak self] buffer,
            _ in

            self?.recognitionRequest?
                .append(buffer)
        }

        audioEngine.prepare()

        do {

            try audioEngine.start()

            isListening = true

            print(
                "[WAKE] listening for Stella"
            )

        } catch {

            print(
                "[WAKE] audio engine failed: \(error.localizedDescription)"
            )

            stop()
            return
        }

        recognitionTask =
            speechRecognizer.recognitionTask(
                with: request
            ) {
                [weak self] result,
                error in

                guard let self else {
                    return
                }

                Task { @MainActor in

                    if let result {

                        let text =
                            result.bestTranscription
                                .formattedString

                        self.lastHeardText = text

                        print(
                            "[WAKE] heard: \(text)"
                        )

                        if self.containsWakePhrase(text),
                           !self.hasTriggeredWake
                        {
                            self.hasTriggeredWake = true

                            print("[WAKE] Stella detected")

                            self.stop()

                            self.onWakeWordDetected?()
                        }
                    }

                    if let error {

                        print(
                            "[WAKE] recognition error: \(error.localizedDescription)"
                        )

                        self.stop()
                    }
                }
            }
    }


    // MARK: - Stop

    func stop() {

        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode
            .removeTap(
                onBus: 0
            )

        isListening = false

        print(
            "[WAKE] stopped"
        )
    }


    // MARK: - Detection

    private func containsWakePhrase(
        _ text: String
    ) -> Bool {

        let normalized = text
            .lowercased()
            .replacingOccurrences(
                of: ".",
                with: ""
            )
            .replacingOccurrences(
                of: ",",
                with: ""
            )
            .replacingOccurrences(
                of: "?",
                with: ""
            )
            .replacingOccurrences(
                of: "!",
                with: ""
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        return wakePhrases.contains {
            phrase in

            normalized.contains(
                phrase
            )
        }
    }
}
