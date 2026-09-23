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

    private let captureEngine: AudioCaptureEngine

    private let speechRecognizer =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var recognitionRequest:
        SFSpeechAudioBufferRecognitionRequest?

    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioListenerID: UUID?
    private var recoveryTask: Task<Void, Never>?

    private var wantsListening = false
    private var generation = UUID()
    private var recognitionFormat: AVAudioFormat?

    init(captureEngine: AudioCaptureEngine) {
        self.captureEngine = captureEngine
    }

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
            await AVCaptureDevice.requestAccess(for: .audio)

        guard microphoneAllowed else {
            print("[WAKE] microphone permission denied")
            return false
        }

        return true
    }

    // MARK: - Lifecycle

    func start() {
        guard !wantsListening else { return }

        wantsListening = true
        lastHeardText = ""
        openRecognition()
    }

    func stop() {
        wantsListening = false

        recoveryTask?.cancel()
        recoveryTask = nil

        closeRecognition()

        // AudioCaptureEngine remains running.
        print("[WAKE] stopped — capture retained")
    }

    private func openRecognition() {
        guard wantsListening else { return }

        closeRecognition()

        guard let recognizer = speechRecognizer,
              recognizer.isAvailable
        else {
            print("[WAKE] recognizer unavailable; retrying")
            scheduleRecovery()
            return
        }

        do {
            // Idempotent when the shared graph is already running.
            try captureEngine.start()
        } catch {
            print(
                "[WAKE] shared capture failed:",
                error.localizedDescription
            )
            stop()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request
        let token = generation
        isListening = true

        recognitionTask = recognizer.recognitionTask(
            with: request
        ) { [weak self] result, error in
            // Transfer simple values to the main queue.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.wantsListening,
                      self.generation == token
                else {
                    return
                }

                if let text {
                    self.lastHeardText = text
                    print("[WAKE] heard: \(text)")

                    if self.containsWakePhrase(text) {
                        print("[WAKE] Stella detected")

                        // Invalidates this recognition session before
                        // invoking the conversation callback.
                        self.stop()
                        self.onWakeWordDetected?()
                        return
                    }
                }

                if let errorMessage {
                    print("[WAKE] recognition error: \(errorMessage)")
                    self.scheduleRecovery()
                } else if isFinal {
                    // A completed request cannot remain our
                    // indefinite wake-listening session.
                    self.scheduleRecovery()
                }
            }
        }

        audioListenerID = captureEngine.addListener {
            [weak self] frame in

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.wantsListening,
                      self.isListening,
                      self.generation == token
                else {
                    return
                }

                self.appendCapture(frame)
            }
        }

        print("[WAKE] listening through shared WebRTC capture")
    }

    private func closeRecognition() {
        // Invalidate queued audio/results before cancelling.
        generation = UUID()
        isListening = false

        if let audioListenerID {
            captureEngine.removeListener(audioListenerID)
            self.audioListenerID = nil
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionTask = nil
        recognitionRequest = nil
        recognitionFormat = nil
    }

    private func scheduleRecovery() {
        guard wantsListening else { return }

        recoveryTask?.cancel()
        closeRecognition()

        let token = generation

        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.wantsListening,
                  self.generation == token
            else {
                return
            }

            self.recoveryTask = nil
            self.openRecognition()
        }
    }

    // MARK: - Shared capture consumer

    private func appendCapture(
        _ frame: AudioCaptureEngine.CaptureFrame
    ) {
        guard let request = recognitionRequest,
              frame.sampleRate > 0,
              !frame.samples.isEmpty
        else {
            return
        }

        if let format = recognitionFormat,
           format.sampleRate != frame.sampleRate {
            // Never mix formats inside one recognition request.
            scheduleRecovery()
            return
        }

        if recognitionFormat == nil {
            recognitionFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: frame.sampleRate,
                channels: 1,
                interleaved: false
            )
        }

        guard let format = recognitionFormat,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frame.samples.count)
              ),
              let destination = buffer.floatChannelData?[0]
        else {
            print("[WAKE] could not create recognition buffer")
            stop()
            return
        }

        buffer.frameLength = AVAudioFrameCount(frame.samples.count)

        frame.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }

            destination.update(
                from: base,
                count: source.count
            )
        }

        request.append(buffer)
    }

    // MARK: - Existing phrase matching

    private func containsWakePhrase(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ["stella", "hey stella"].contains {
            normalized.contains($0)
        }
    }
}
