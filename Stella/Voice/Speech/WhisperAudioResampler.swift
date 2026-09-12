//
//  WhisperAudioResampler.swift
//  Stella
//
//  Converts Stella microphone audio into Whisper's
//  required 16 kHz mono Float32 format.
//

import Foundation
import AVFoundation

enum WhisperAudioResampler {

    static let whisperSampleRate: Double = 16_000

    enum ResamplerError: LocalizedError {

        case invalidSampleRate
        case formatCreationFailed
        case bufferCreationFailed
        case converterCreationFailed
        case missingChannelData
        case conversionFailed(String)

        var errorDescription: String? {

            switch self {

            case .invalidSampleRate:
                return "Invalid source sample rate."

            case .formatCreationFailed:
                return "Could not create audio conversion format."

            case .bufferCreationFailed:
                return "Could not create audio conversion buffer."

            case .converterCreationFailed:
                return "Could not create Whisper audio converter."

            case .missingChannelData:
                return "Audio buffer does not contain Float32 channel data."

            case .conversionFailed(let message):
                return "Whisper audio resampling failed: \(message)"
            }
        }
    }

    static func resample(
        samples: [Float],
        from sourceSampleRate: Double
    ) throws -> [Float] {

        guard !samples.isEmpty else {
            return []
        }

        guard sourceSampleRate > 0 else {
            throw ResamplerError.invalidSampleRate
        }

        // Already Whisper-compatible.
        if abs(sourceSampleRate - whisperSampleRate) < 0.5 {
            return samples
        }

        // MARK: - Formats

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ResamplerError.formatCreationFailed
        }

        guard let destinationFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: whisperSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ResamplerError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(
            from: sourceFormat,
            to: destinationFormat
        ) else {
            throw ResamplerError.converterCreationFailed
        }

        // MARK: - Input Buffer

        let inputFrameCount =
            AVAudioFrameCount(samples.count)

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: inputFrameCount
        ) else {
            throw ResamplerError.bufferCreationFailed
        }

        inputBuffer.frameLength =
            inputFrameCount

        guard let inputChannel =
                inputBuffer.floatChannelData?[0] else {
            throw ResamplerError.missingChannelData
        }

        samples.withUnsafeBufferPointer { buffer in

            guard let baseAddress =
                    buffer.baseAddress else {
                return
            }

            inputChannel.update(
                from: baseAddress,
                count: samples.count
            )
        }

        // MARK: - Output Buffer

        let ratio =
            whisperSampleRate
            /
            sourceSampleRate

        // Enough room for resampled data plus converter
        // priming / rounding headroom.
        let estimatedOutputFrames =
            Int(
                ceil(
                    Double(samples.count)
                    *
                    ratio
                )
            )

        let outputCapacity =
            AVAudioFrameCount(
                estimatedOutputFrames + 1024
            )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: outputCapacity
        ) else {
            throw ResamplerError.bufferCreationFailed
        }

        // MARK: - Sample Rate Conversion

        var conversionError: NSError?

        var suppliedInput = false

        let status =
            converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) {
                _, inputStatus in

                // This utterance is one complete source buffer.
                // Supply it exactly once.
                if !suppliedInput {

                    suppliedInput = true

                    inputStatus.pointee =
                        .haveData

                    return inputBuffer
                }

                // Tell AVAudioConverter there is no more source
                // audio after the completed utterance.
                inputStatus.pointee =
                    .endOfStream

                return nil
            }

        switch status {

        case .haveData,
             .inputRanDry,
             .endOfStream:

            break

        case .error:

            let message =
                conversionError?.localizedDescription
                ?? "Unknown AVAudioConverter error."

            throw ResamplerError.conversionFailed(
                message
            )

        @unknown default:

            throw ResamplerError.conversionFailed(
                "Unknown AVAudioConverter output status."
            )
        }

        // MARK: - Extract Converted Samples

        guard let outputChannel =
                outputBuffer.floatChannelData?[0] else {
            throw ResamplerError.missingChannelData
        }

        let outputFrameCount =
            Int(outputBuffer.frameLength)

        guard outputFrameCount > 0 else {

            throw ResamplerError.conversionFailed(
                "Converter produced zero output frames."
            )
        }

        return Array(
            UnsafeBufferPointer(
                start: outputChannel,
                count: outputFrameCount
            )
        )
    }
}
