import Foundation
@preconcurrency import AVFoundation
import Combine



private final class LockedSampleBuffer: @unchecked Sendable {

    private let lock = NSLock()
    private var samples: [Float] = []
    private let spectrumAnalyzer =
        AudioSpectrumAnalyzer()
    
    func clear() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        
        spectrumAnalyzer?.reset()
    }

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
        spectrumAnalyzer?.analyze(
            samples: newSamples,
            sampleRate: 16_000
        )
    }
    
    func spectrumSnapshot()
        -> AudioSpectrum
    {
        spectrumAnalyzer?
            .snapshot()
            ?? .zero
    }
    
    func snapshot() -> [Float] {
        lock.lock()
        let copy = samples
        lock.unlock()

        return copy
    }
    
    func count() -> Int {

        lock.lock()
        let count = samples.count
        lock.unlock()

        return count
    }
}


@MainActor
final class MicrophoneRecorder: ObservableObject {

    enum RecorderError: Error, LocalizedError {
        case microphoneUnavailable
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                return "Microphone input is unavailable."

            case .converterCreationFailed:
                return "Couldn't create the audio converter."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    
    let engine = AVAudioEngine()

    private let sampleBuffer =
        LockedSampleBuffer()
    var sampleCount: Int {
        sampleBuffer.count()
    }

    func spectrumSnapshot() -> AudioSpectrum {
        sampleBuffer.spectrumSnapshot()
    }

    private static func makeTargetFormat()
        -> AVAudioFormat
    {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    private var engineStarted = false

    func start() throws {

        guard !isRecording else {
            return
        }
        sampleBuffer.clear()

        let inputNode = engine.inputNode

        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.microphoneUnavailable
        }

        let targetFormat = Self.makeTargetFormat()

        guard let converter =
                AVAudioConverter(
                    from: inputFormat,
                    to: targetFormat
                )
        else {
            throw RecorderError.converterCreationFailed
        }

        let storage = sampleBuffer

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in

            guard let converted = Self.convert(
                buffer,
                using: converter,
                targetFormat: targetFormat
            ) else {
                return
            }

            storage.append(converted.samples)

            let levelValue = converted.level

            Task { @MainActor [weak self] in
                self?.level = levelValue
            }
        }

        if !engineStarted {
            // Must happen before the engine's first start, and after
            // Kokoro has already attached its player node (see file 2) —
            // that's the reference signal AEC subtracts from the mic.
            try? inputNode.setVoiceProcessingEnabled(true)

            engine.prepare()
            try engine.start()
            engineStarted = true
        }

        isRecording = true

        print("[MIC] recording started")
    }

    func stop() -> [Float] {

        guard isRecording else {
            return []
        }

        engine.inputNode.removeTap(onBus: 0)
        // Deliberately not calling engine.stop() — Kokoro's player node
        // lives on this same engine now, and AEC doesn't like being
        // torn down and rebuilt every turn.

        isRecording = false
        level = 0

        let samples = sampleBuffer.snapshot()

        print("[MIC] recording stopped — \(samples.count) samples")

        return samples
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> (
        samples: [Float],
        level: Float
    )? {
        
        guard buffer.frameLength > 0 else {
                return nil
            }
        let ratio =
            targetFormat.sampleRate /
            buffer.format.sampleRate

        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio
        ) + 1

        guard let convertedBuffer =
                AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: capacity
                )
        else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        

        let status = converter.convert(
            to: convertedBuffer,
            error: &conversionError
        ) { _, inputStatus in

            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }

            suppliedInput = true

            inputStatus.pointee =
                .haveData

            return buffer
        }

        guard conversionError == nil else {
            print(
                "[MIC] conversion error: \(conversionError!.localizedDescription)"
            )
            return nil
        }

        guard status != .error else {
            return nil
        }

        guard
            let channel =
                convertedBuffer.floatChannelData?[0]
        else {
            return nil
        }

        let count =
            Int(convertedBuffer.frameLength)

        guard count > 0 else {
            return nil
        }

        let samples = Array(
            UnsafeBufferPointer(
                start: channel,
                count: count
            )
        )

        var squareSum: Float = 0
        

        for sample in samples {
            squareSum += sample * sample
        }

        let rms = sqrt(
            squareSum /
            Float(samples.count)
        )

        return (
            samples: samples,
            level: rms
        )
    }
}
