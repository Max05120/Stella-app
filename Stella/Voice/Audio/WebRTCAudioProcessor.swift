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
        let renderEnvelope: Float
        
        let rawCaptureRMS: Float
        let processedCaptureRMS: Float
        
        let renderCorrelation: Float
        let correlationLagMs: Int
        
        var suppressionRatio: Float {
            processedCaptureRMS /
            max(
                rawCaptureRMS,
                0.0001
            )
        }
        var captureToRenderRatio: Float {
            processedCaptureRMS /
            max(renderRMS, 0.0001)
        }
    }
    

    private var latestRenderRMS: Float = 0
    
    private var recentRenderRMS: [Float] = []
    private let renderHistorySize = 25   // 250 ms
    
    // 500 ms of actual 24 kHz render audio.
    //
    // We retain more than the 250 ms analysis window so correlation
    // can search across speaker -> mic / AEC timing differences.
    private let renderWaveformCapacity = 12_000

    private var renderWaveformHistory: [Float] = []

    private var latestRenderCorrelation: Float = 0
    private var latestCorrelationLagMs: Int = 0
    private let correlationCaptureCapacity =
        4_800     // 100 ms @ 48 kHz

    private var rawCaptureHistory: [Float] = []
    
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
            
            rawCaptureHistory.append(
                contentsOf: frame
            )

            if rawCaptureHistory.count >
                correlationCaptureCapacity
            {
                rawCaptureHistory.removeFirst(
                    rawCaptureHistory.count -
                    correlationCaptureCapacity
                )
            }
            
            if rawCaptureHistory.count ==
                correlationCaptureCapacity
            {
                updateRenderCorrelation(
                    rawCaptureFrame:
                        rawCaptureHistory
                )
            }
            
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
            renderWaveformHistory.append(
                contentsOf: frame
            )

            if renderWaveformHistory.count >
                renderWaveformCapacity
            {
                let overflow =
                    renderWaveformHistory.count -
                    renderWaveformCapacity

                renderWaveformHistory.removeFirst(
                    overflow
                )
            }

            latestRenderRMS =
                renderRMS
            recentRenderRMS.append(
                renderRMS
            )

            if recentRenderRMS.count >
                renderHistorySize
            {
                recentRenderRMS.removeFirst(
                    recentRenderRMS.count -
                    renderHistorySize
                )
            }

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
    
    private func normalizedCorrelation(
        _ capture: [Float],
        _ render: ArraySlice<Float>
    ) -> Float {

        guard capture.count == render.count,
              !capture.isEmpty
        else {
            return 0
        }

        var dot: Float = 0
        var captureEnergy: Float = 0
        var renderEnergy: Float = 0

        var renderIndex =
            render.startIndex

        for captureSample in capture {

            let renderSample =
                render[renderIndex]

            dot +=
                captureSample *
                renderSample

            captureEnergy +=
                captureSample *
                captureSample

            renderEnergy +=
                renderSample *
                renderSample

            renderIndex += 1
        }

        let denominator =
            sqrt(
                captureEnergy *
                renderEnergy
            )

        guard denominator > 0.000001
        else {
            return 0
        }

        return dot / denominator
    }
    
    
    private func downsampleCaptureTo24k(
        _ samples: [Float]
    ) -> [Float] {

        guard samples.count >= 2
        else {
            return samples
        }

        var result: [Float] = []
        result.reserveCapacity(
            samples.count / 2
        )

        var index = 0

        while index + 1 <
                samples.count
        {
            let averaged =
                (
                    samples[index] +
                    samples[index + 1]
                ) * 0.5

            result.append(
                averaged
            )

            index += 2
        }

        return result
    }
    
    private func updateRenderCorrelation(
        rawCaptureFrame: [Float]
    ) {

        let capture24k =
            downsampleCaptureTo24k(
                rawCaptureFrame
            )

        guard !capture24k.isEmpty else {
            latestRenderCorrelation = 0
            latestCorrelationLagMs = 0
            return
        }

        let windowSize =
            capture24k.count

        guard renderWaveformHistory.count >=
                windowSize
        else {
            latestRenderCorrelation = 0
            latestCorrelationLagMs = 0
            return
        }

        // Search up to 250 ms into recent render history.
        let maximumLagSamples =
            min(
                6_000,
                renderWaveformHistory.count -
                windowSize
            )

        // Search in 10 ms increments.
        //
        // 24 kHz * 0.010 sec = 240 samples.
        let lagStep = 240

        var bestCorrelation: Float = 0
        var bestLagSamples = 0

        var lag = 0

        while lag <= maximumLagSamples {

            let end =
                renderWaveformHistory.count -
                lag

            let start =
                end -
                windowSize

            guard start >= 0,
                  end <=
                    renderWaveformHistory.count
            else {
                break
            }

            let renderWindow =
                renderWaveformHistory[
                    start..<end
                ]

            let correlation =
                abs(
                    normalizedCorrelation(
                        capture24k,
                        renderWindow
                    )
                )

            if correlation >
                bestCorrelation
            {
                bestCorrelation =
                    correlation

                bestLagSamples =
                    lag
            }

            lag += lagStep
        }

        latestRenderCorrelation =
            bestCorrelation

        latestCorrelationLagMs =
            Int(
                Double(bestLagSamples)
                / 24_000.0
                * 1000.0
            )
    }
    
    private func renderEnvelopeLocked()
        -> Float
    {
        guard !recentRenderRMS.isEmpty else {
            return 0
        }

        let peak =
            recentRenderRMS.max() ?? 0

        let mean =
            recentRenderRMS.reduce(0, +)
            / Float(recentRenderRMS.count)

        return max(
            mean,
            peak * 0.5
        )
    }
    
    func currentBargeDiagnostics()
        -> BargeDiagnostics
    {
        lock.lock()
        defer { lock.unlock() }
        
        return BargeDiagnostics(
            renderRMS: latestRenderRMS,
            renderEnvelope: renderEnvelopeLocked(),
            rawCaptureRMS: latestRawCaptureRMS,
            processedCaptureRMS: latestProcessedCaptureRMS,
            renderCorrelation: latestRenderCorrelation,
            correlationLagMs: latestCorrelationLagMs,
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
        recentRenderRMS.removeAll(
            keepingCapacity: true
        )
        rawCaptureHistory.removeAll(
            keepingCapacity: true
        )
        latestRenderRMS = 0
        latestRawCaptureRMS = 0
        latestProcessedCaptureRMS = 0
        latestRenderCorrelation = 0
        latestCorrelationLagMs = 0
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
