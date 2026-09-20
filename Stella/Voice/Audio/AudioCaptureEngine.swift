//
//  instead.swift
//  Stella
//
//  Created by Harish Maheshwaran on 10/09/26.
//


//
//  AudioCaptureEngine.swift
//  Stella
//
//  Central microphone owner for Stella.
//
//  Architecture rule:
//
//      ONE AVAudioEngine
//      ONE inputNode.installTap()
//      ONE component responsible for microphone capture
//
//  Wake word, conversation recording, VAD and barge-in must eventually
//  consume audio from this class instead of creating their own taps.
//

import Foundation
import AVFoundation

final class AudioCaptureEngine: @unchecked Sendable {

    // MARK: - Capture Frame

    struct CaptureFrame: Sendable {

        /// Mono Float32 microphone samples after preprocessing.
        ///
        /// Equal to the concatenation of `subFrames.map(\.samples)`.
        /// Consumers that don't need per-sub-frame AEC metrics
        /// (recording, Whisper, turn detection) can keep using this
        /// exactly as before.
        let samples: [Float]

        /// Sample rate of the captured input buffer.
        let sampleRate: Double

        /// Number of channels in the original microphone buffer.
        let sourceChannelCount: Int

        /// Host timestamp supplied by AVAudioEngine.
        let hostTime: UInt64

        /// `samples` broken into its true ~10 ms AEC sub-frames,
        /// each paired with the metrics computed from that exact
        /// sub-frame. Consumers that need audio and acoustic context
        /// to line up exactly (BargeInDetector) should iterate this
        /// instead of re-deriving metrics separately.
        let subFrames: [AECProcessedFrame]
    }

    // MARK: - Listener

    typealias AudioListener = (CaptureFrame) -> Void

    // MARK: - Errors

    enum AudioCaptureError: LocalizedError {

        case invalidInputFormat
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {

            case .invalidInputFormat:
                return "The microphone returned an invalid audio format."

            case .microphoneUnavailable:
                return "No usable microphone input is currently available."
            }
        }
    }

    // MARK: - Audio

    private let engine: AVAudioEngine
    // Migration-only playback access.
    // Kokoro must share the same audio graph as capture.
    var playbackEngine: AVAudioEngine {
        engine
    }
    private let preprocessor: AudioPreprocessor

    // MARK: - State

    private let stateLock = NSLock()

    private var listeners: [UUID: AudioListener] = [:]

    private var tapInstalled = false
    private var shouldBeRunning = false

    // MARK: - Device Changes

    private var configurationObserver: NSObjectProtocol?

    // MARK: - Init

    init(
        preprocessor: AudioPreprocessor = PassthroughAudioProcessor()
    ) {

        self.engine = AVAudioEngine()
        self.preprocessor = preprocessor

        observeAudioConfigurationChanges()
    }

    deinit {

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }

        stop()
    }

    // MARK: - Public State

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        return engine.isRunning && tapInstalled
    }

    // MARK: - Listener Registration

    /// Registers a consumer of Stella's microphone stream.
    ///
    /// Future consumers can include:
    ///
    /// - VoiceActivityDetector
    /// - TurnDetector
    /// - WakeWordListener
    /// - BargeInDetector
    ///
    /// The returned UUID must be retained by the consumer so it can
    /// unregister later.
    @discardableResult
    func addListener(
        _ listener: @escaping AudioListener
    ) -> UUID {

        let id = UUID()

        stateLock.lock()
        listeners[id] = listener
        stateLock.unlock()

        return id
    }

    func removeListener(_ id: UUID) {

        stateLock.lock()
        listeners.removeValue(forKey: id)
        stateLock.unlock()
    }

    // MARK: - Start

    func start() throws {

        stateLock.lock()

        if engine.isRunning && tapInstalled {
            shouldBeRunning = true

            stateLock.unlock()
            return
        }

        shouldBeRunning = true

        stateLock.unlock()

        try configureAndStartEngine()
    }

    // MARK: - Stop

    func stop() {

        stateLock.lock()

        shouldBeRunning = false

        let needsTapRemoval = tapInstalled
        tapInstalled = false

        stateLock.unlock()

        let inputNode = engine.inputNode

        if needsTapRemoval {
            inputNode.removeTap(onBus: 0)
        }

        if engine.isRunning {
            engine.stop()
        }

        engine.reset()

        preprocessor.reset()
    }

    // MARK: - Render Reference

    /// Supplies Stella's outgoing audio to the preprocessing layer.
    ///
    /// Nothing consumes this in Phase 1.
    ///
    /// Later:
    ///
    /// Kokoro
    ///     ↓
    /// VoiceOutputManager
    ///     ↓
    /// processRenderReference(...)
    ///     ↓
    /// WebRTC AEC3
    ///
    /// Having this path now prevents us from redesigning the capture
    /// architecture when echo cancellation is introduced.
    func processRenderReference(_ samples: [Float]) {

        guard !samples.isEmpty else {
            return
        }

        preprocessor.processRender(samples)
    }

    // MARK: - Engine Configuration

    private func configureAndStartEngine() throws {

        let inputNode = engine.inputNode

        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        guard format.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        removeExistingOwnedTapIfNeeded()

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { [weak self] buffer, time in

            self?.handleInputBuffer(
                buffer,
                time: time
            )
        }

        stateLock.lock()
        tapInstalled = true
        stateLock.unlock()

        engine.prepare()

        do {

            try engine.start()

        } catch {

            inputNode.removeTap(onBus: 0)

            stateLock.lock()
            tapInstalled = false
            stateLock.unlock()

            throw error
        }
    }

    // MARK: - Input Processing

    private func handleInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        time: AVAudioTime
    ) {

        guard buffer.frameLength > 0 else {
            return
        }

        guard let channelData = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        guard frameCount > 0,
              channelCount > 0 else {
            return
        }

        let monoSamples = makeMonoSamples(
            channelData: channelData,
            frameCount: frameCount,
            channelCount: channelCount
        )

        guard !monoSamples.isEmpty else {
            return
        }

        let subFrames = preprocessor.processCapture(
            monoSamples
        )

        guard !subFrames.isEmpty else {
            return
        }

        let processedSamples = subFrames.flatMap {
            $0.samples
        }

        let frame = CaptureFrame(
            samples: processedSamples,
            sampleRate: buffer.format.sampleRate,
            sourceChannelCount: channelCount,
            hostTime: time.hostTime,
            subFrames: subFrames
        )

        notifyListeners(frame)
    }

    // MARK: - Mono Conversion

    /// Converts any input channel layout to mono.
    ///
    /// Most Mac microphones are already mono, so the common path simply
    /// copies channel zero.
    ///
    /// Multi-channel input is averaged instead of arbitrarily discarding
    /// every channel except the first.
    private func makeMonoSamples(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {

        if channelCount == 1 {

            let pointer = channelData[0]

            return Array(
                UnsafeBufferPointer(
                    start: pointer,
                    count: frameCount
                )
            )
        }

        var mono = [Float](
            repeating: 0,
            count: frameCount
        )

        let normalization = 1.0 / Float(channelCount)

        for channel in 0..<channelCount {

            let samples = channelData[channel]

            for frame in 0..<frameCount {
                mono[frame] += samples[frame] * normalization
            }
        }

        return mono
    }

    // MARK: - Listener Distribution

    private func notifyListeners(
        _ frame: CaptureFrame
    ) {

        stateLock.lock()

        let currentListeners = Array(
            listeners.values
        )

        stateLock.unlock()

        for listener in currentListeners {
            listener(frame)
        }
    }

    // MARK: - Tap Ownership

    private func removeExistingOwnedTapIfNeeded() {

        stateLock.lock()

        let needsRemoval = tapInstalled
        tapInstalled = false

        stateLock.unlock()

        guard needsRemoval else {
            return
        }

        engine.inputNode.removeTap(
            onBus: 0
        )
    }

    // MARK: - Audio Device / Graph Changes

    private func observeAudioConfigurationChanges() {

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in

            self?.handleAudioConfigurationChange()
        }
    }

    private func handleAudioConfigurationChange() {

        stateLock.lock()

        let restartRequired = shouldBeRunning

        tapInstalled = false

        stateLock.unlock()

        guard restartRequired else {
            return
        }

        if engine.isRunning {
            engine.stop()
        }

        engine.reset()

        do {

            try configureAndStartEngine()

            print(
                "[AUDIO] capture engine restarted after configuration change"
            )

        } catch {

            print(
                "[AUDIO] failed to restart capture engine:",
                error.localizedDescription
            )
        }
    }
}
