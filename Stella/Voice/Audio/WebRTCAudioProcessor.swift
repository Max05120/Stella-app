import Foundation

final class WebRTCAudioProcessor: AudioPreprocessor {

    private var handle: StellaAPMHandle?

    // WebRTC APM processes 10 ms frames.
    // Stella's centralized capture currently runs at 48 kHz,
    // therefore one APM frame = 480 samples.
    private let captureSampleRate: Int32 = 48_000
    private let captureFrameSize = 480

    // Samples that did not form a complete 10 ms frame during
    // the previous AudioCaptureEngine callback.
    private var captureRemainder: [Float] = []
    private let renderSampleRate: Int32 = 24_000
    private let renderFrameSize = 240

    private var renderRemainder: [Float] = []

    private var didLogRenderProcessing = false

    private let lock = NSLock()
    struct BargeDiagnostics: Sendable {
        let renderRMS: Float
        let rawCaptureRMS: Float
        let processedCaptureRMS: Float

        var captureToRenderRatio: Float {
            processedCaptureRMS /
            max(renderRMS, 0.0001)
        }
    }

    private var latestRenderRMS: Float = 0
    private var latestRawCaptureRMS: Float = 0
    private var latestProcessedCaptureRMS: Float = 0

//    private var diagnosticsFrameCounter = 0

    var isReady: Bool {
        guard let handle else {
            return false
        }

        return StellaAPMIsReady(handle)
    }

    init() {
        handle = StellaAPMCreate()

        if let handle, StellaAPMIsReady(handle) {
            print("[WEBRTC] APM created successfully")
        } else {
            print("[WEBRTC] APM creation failed")
        }
    }

    deinit {
        if let handle {
            StellaAPMDestroy(handle)
            print("[WEBRTC] APM destroyed")
        }
    }

    func processCapture(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else {
            return []
        }

        guard let handle, StellaAPMIsReady(handle) else {
            return samples
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        captureRemainder.append(contentsOf: samples)

        var processedSamples: [Float] = []
        processedSamples.reserveCapacity(
            captureRemainder.count
        )

        while captureRemainder.count >= captureFrameSize {

            var frame = Array(
                captureRemainder.prefix(
                    captureFrameSize
                )
            )

            captureRemainder.removeFirst(
                captureFrameSize
            )

            let rawRMS = sqrt(
                frame.reduce(0) {
                    $0 + $1 * $1
                } /
                Float(frame.count)
            )

            let success =
                frame.withUnsafeMutableBufferPointer { buffer in

                    guard let baseAddress =
                            buffer.baseAddress
                    else {
                        return false
                    }

                    return StellaAPMProcessCapture(
                        handle,
                        baseAddress,
                        Int32(buffer.count),
                        captureSampleRate
                    )
                }

            let processedRMS = sqrt(
                frame.reduce(0) {
                    $0 + $1 * $1
                } /
                Float(frame.count)
            )

            latestRawCaptureRMS =
                rawRMS

            latestProcessedCaptureRMS =
                processedRMS

            if !success {
                print(
                    "[WEBRTC] capture processing failed"
                )
            }

            processedSamples.append(
                contentsOf: frame
            )
        }

        return processedSamples
    }

    
    func processRender(_ samples: [Float]) {
        guard !samples.isEmpty else {
            return
        }

        guard let handle, StellaAPMIsReady(handle) else {
            return
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        renderRemainder.append(contentsOf: samples)

        while renderRemainder.count >= renderFrameSize {

            let frame = Array(
                renderRemainder.prefix(renderFrameSize)
            )

            renderRemainder.removeFirst(
                renderFrameSize
            )
            
            let renderRMS = sqrt(
                frame.reduce(0) {
                    $0 + $1 * $1
                } /
                Float(frame.count)
            )

            latestRenderRMS =
                renderRMS

            let success =
                frame.withUnsafeBufferPointer { buffer in

                    guard let baseAddress =
                            buffer.baseAddress else {
                        return false
                    }

                    return StellaAPMProcessRender(
                        handle,
                        baseAddress,
                        Int32(buffer.count),
                        renderSampleRate
                    )
                }

            if !success {
                print(
                    "[WEBRTC] render processing failed"
                )
            } else if !didLogRenderProcessing {
                didLogRenderProcessing = true

                print(
                    "[WEBRTC] render stream processing active — 24kHz / 240 samples"
                )
            }
        }
    }
    
    func currentBargeDiagnostics()
        -> BargeDiagnostics
    {
        lock.lock()
        defer { lock.unlock() }

        return BargeDiagnostics(
            renderRMS: latestRenderRMS,
            rawCaptureRMS: latestRawCaptureRMS,
            processedCaptureRMS:
                latestProcessedCaptureRMS
        )
    }

    func reset() {
        lock.lock()

        captureRemainder.removeAll(
            keepingCapacity: true
        )

        renderRemainder.removeAll(
            keepingCapacity: true
        )
        latestRenderRMS = 0
        latestRawCaptureRMS = 0
        latestProcessedCaptureRMS = 0
//        diagnosticsFrameCounter = 0
        
        didLogRenderProcessing = false

        lock.unlock()
    }

    // Temporary Phase 5D bridge test.
    func debugCaptureSmokeTest() {
        guard let handle else {
            print("[WEBRTC TEST] no APM handle")
            return
        }

        var frame = [Float](
            repeating: 0.0,
            count: captureFrameSize
        )

        
        let success =
            frame.withUnsafeMutableBufferPointer { buffer in

                guard let baseAddress =
                        buffer.baseAddress else {
                    return false
                }

                return StellaAPMProcessCapture(
                    handle,
                    baseAddress,
                    Int32(buffer.count),
                    captureSampleRate
                )
            }

        print(
            "[WEBRTC TEST] 48k capture frame processed =",
            success
        )
    }
}
