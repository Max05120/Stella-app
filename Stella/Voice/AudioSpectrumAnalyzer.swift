import Foundation
import Accelerate

struct AudioSpectrum: Equatable, Sendable {
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0

    static let zero = AudioSpectrum()
}

final class AudioSpectrumAnalyzer: @unchecked Sendable {

    private let lock = NSLock()

    private var current: AudioSpectrum = .zero

    private let fftSize = 1024
    private let log2n: vDSP_Length

    private let fftSetup: FFTSetup

    private var window: [Float]

    init?() {
        log2n = vDSP_Length(log2(Float(fftSize)))

        guard let setup = vDSP_create_fftsetup(
            log2n,
            FFTRadix(kFFTRadix2)
        ) else {
            return nil
        }

        fftSetup = setup

        window = [Float](
            repeating: 0,
            count: fftSize
        )

        vDSP_hann_window(
            &window,
            vDSP_Length(fftSize),
            Int32(vDSP_HANN_NORM)
        )
    }

    deinit {
        vDSP_destroy_fftsetup(
            fftSetup
        )
    }

    func analyze(
        samples: [Float],
        sampleRate: Float
    ) {
        guard samples.count >= fftSize else {
            return
        }

        var input = Array(
            samples.suffix(fftSize)
        )

        // Window the signal to reduce spectral leakage.
        vDSP_vmul(
            input,
            1,
            window,
            1,
            &input,
            1,
            vDSP_Length(fftSize)
        )

        let halfCount = fftSize / 2

        var real = [Float](
            repeating: 0,
            count: halfCount
        )

        var imag = [Float](
            repeating: 0,
            count: halfCount
        )

        input.withUnsafeBufferPointer { inputBuffer in
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in

                    guard
                        let inputBase = inputBuffer.baseAddress,
                        let realBase = realBuffer.baseAddress,
                        let imagBase = imagBuffer.baseAddress
                    else {
                        return
                    }

                    inputBase.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfCount
                    ) { complexInput in

                        var split = DSPSplitComplex(
                            realp: realBase,
                            imagp: imagBase
                        )

                        vDSP_ctoz(
                            complexInput,
                            2,
                            &split,
                            1,
                            vDSP_Length(halfCount)
                        )

                        vDSP_fft_zrip(
                            fftSetup,
                            &split,
                            1,
                            log2n,
                            FFTDirection(
                                kFFTDirection_Forward
                            )
                        )
                    }
                }
            }
        }

        var magnitudes = [Float](
            repeating: 0,
            count: halfCount
        )

        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in

                guard
                    let realBase = realBuffer.baseAddress,
                    let imagBase = imagBuffer.baseAddress
                else {
                    return
                }

                var split = DSPSplitComplex(
                    realp: realBase,
                    imagp: imagBase
                )

                vDSP_zvmags(
                    &split,
                    1,
                    &magnitudes,
                    1,
                    vDSP_Length(halfCount)
                )
            }
        }

//        // sqrt(power) -> magnitude
//        var count = Int32(halfCount)
//
//        vvrsqrtf(
//            &magnitudes,
//            magnitudes,
//            &count
//        )

        // The previous call gives inverse sqrt, so don't use that.
        // Calculate magnitudes properly instead.
        for i in 0..<halfCount {
            let re = real[i]
            let im = imag[i]

            magnitudes[i] =
                sqrt(re * re + im * im)
        }

        var rms: Float = 0

        vDSP_rmsqv(
            input,
            1,
            &rms,
            vDSP_Length(input.count)
        )

        let binWidth =
            sampleRate / Float(fftSize)

        let next = AudioSpectrum(
            level: normalizeRMS(rms),
            bass: normalizeBand(
                averageBand(
                    magnitudes,
                    lowHz: 70,
                    highHz: 250,
                    binWidth: binWidth
                ),
                gain: 0.030
            ),
            mid: normalizeBand(
                averageBand(
                    magnitudes,
                    lowHz: 250,
                    highHz: 2_000,
                    binWidth: binWidth
                ),
                gain: 0.020
            ),
            high: normalizeBand(
                averageBand(
                    magnitudes,
                    lowHz: 2_000,
                    highHz: 8_000,
                    binWidth: binWidth
                ),
                gain: 0.014
            )
        )

        lock.lock()

        current = AudioSpectrum(
            level: envelope(
                previous: current.level,
                target: next.level
            ),
            bass: envelope(
                previous: current.bass,
                target: next.bass
            ),
            mid: envelope(
                previous: current.mid,
                target: next.mid
            ),
            high: envelope(
                previous: current.high,
                target: next.high
            )
        )

        lock.unlock()
    }

    func snapshot() -> AudioSpectrum {
        lock.lock()
        let copy = current
        lock.unlock()

        return copy
    }

    func reset() {
        lock.lock()
        current = .zero
        lock.unlock()
    }

    private func averageBand(
        _ magnitudes: [Float],
        lowHz: Float,
        highHz: Float,
        binWidth: Float
    ) -> Float {

        let start = max(
            1,
            Int(lowHz / binWidth)
        )

        let end = min(
            magnitudes.count - 1,
            Int(highHz / binWidth)
        )

        guard end >= start else {
            return 0
        }

        var total: Float = 0

        for i in start...end {
            total += magnitudes[i]
        }

        return total /
            Float(end - start + 1)
    }

    private func normalizeRMS(
        _ value: Float
    ) -> Float {
        // Speech RMS tends to be small.
        let boosted = value * 18

        return min(
            max(boosted, 0),
            1
        )
    }

    private func normalizeBand(
        _ value: Float,
        gain: Float
    ) -> Float {

        // Log-style compression gives much nicer visuals
        // than a raw linear spectrum.
        let compressed =
            log10(1 + value * gain * 1000)

        return min(
            max(compressed / 1.6, 0),
            1
        )
    }

    private func envelope(
        previous: Float,
        target: Float
    ) -> Float {

        // Fast attack, slow decay.
        let coefficient: Float =
            target > previous
            ? 0.58
            : 0.16

        let value =
            previous +
            (target - previous) *
            coefficient

        // Snap tiny residual values to zero.
        return value < 0.001
            ? 0
            : value
    }
}
