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

    // Correlation is the most expensive computation here — a lag
    // search over up to ~250 ms of render history, done every 10 ms
    // once history fills. Running it synchronously inside the
    // real-time capture callback is a real suspect for the
    // HALC_ProxyIOContext::IOWorkLoop overload warnings and the
    // AEC3 delay-instability / buffer-overrun-reset lines this
    // project has logged in the same sessions where suppression
    // stops looking meaningful. It now runs on a background queue,
    // throttled, instead of inline on the capture thread.
    private let correlationQueue = DispatchQueue(
        label: "com.stella.aec.correlationAnalysis",
        qos: .utility
    )
    private var correlationInFlight = false
    private var framesSinceLastCorrelationUpdate = 0
    private let correlationUpdateStride = 3   // roughly every ~30 ms

    // Bumped by reset(). Lets a straggling background correlation
    // result from a previous speaking turn recognize it's stale and
    // discard itself instead of overwriting the new turn's data.
    private var resetGeneration = 0

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

    func processCapture(_ samples: [Float]) -> [AECProcessedFrame] {
        guard !samples.isEmpty else {
            return []
        }

        guard let handle, StellaAPMIsReady(handle) else {

            // No AEC available — still hand back real sub-frame
            // boundaries with zeroed metrics, matching
            // PassthroughAudioProcessor's shape, so callers never
            // have to special-case "AEC unavailable".
            let metrics = AECFrameMetrics(
                rawRMS: 0,
                processedRMS: 0,
                renderRMS: 0,
                renderEnvelope: 0,
                correlation: 0,
                correlationLagMs: 0
            )

            return [
                AECProcessedFrame(
                    samples: samples,
                    metrics: metrics
                )
            ]
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        captureRemainder.append(contentsOf: samples)

        var processedFrames: [AECProcessedFrame] = []

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
                scheduleRenderCorrelationUpdate()
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

            if !success {
                print(
                    "[WEBRTC] capture processing failed"
                )
            }

            // Built right here, from the same rawRMS/processedRMS
            // just computed for THIS frame, and from render/
            // correlation state as it stands at this exact instant
            // — not fetched later via a separate snapshot call.
            let metrics = AECFrameMetrics(
                rawRMS: rawRMS,
                processedRMS: processedRMS,
                renderRMS: latestRenderRMS,
                renderEnvelope: renderEnvelopeLocked(),
                correlation: latestRenderCorrelation,
                correlationLagMs: latestCorrelationLagMs
            )

            processedFrames.append(
                AECProcessedFrame(
                    samples: frame,
                    metrics: metrics
                )
            )
        }

        return processedFrames
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
    
    private static func normalizedCorrelation(
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
    
    
    private static func downsampleCaptureTo24k(
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
    
    /// Kicks off an off-thread correlation update, throttled so it
    /// runs roughly every `correlationUpdateStride` sub-frames
    /// instead of every single one, and skipped entirely while a
    /// previous update is still running. Must be called with `lock`
    /// already held — it is, from inside `processCapture`.
    private func scheduleRenderCorrelationUpdate() {

        framesSinceLastCorrelationUpdate += 1

        guard !correlationInFlight,
              framesSinceLastCorrelationUpdate >=
                correlationUpdateStride
        else {
            return
        }

        framesSinceLastCorrelationUpdate = 0
        correlationInFlight = true

        // Snapshots. Cheap right here — Swift arrays are
        // copy-on-write, so this is a reference bump, not a copy,
        // until one side mutates. The expensive lag search happens
        // off the capture thread, on these frozen snapshots, not on
        // the live history arrays the capture thread keeps mutating.
        let captureSnapshot = rawCaptureHistory
        let renderSnapshot = renderWaveformHistory
        let generation = resetGeneration

        correlationQueue.async { [weak self] in

            guard let self else {
                return
            }

            let result = Self.computeRenderCorrelation(
                rawCaptureFrame: captureSnapshot,
                renderHistory: renderSnapshot
            )

            self.lock.lock()
            defer { self.lock.unlock() }

            guard self.resetGeneration == generation else {
                // A reset happened while this was computing — this
                // result describes audio from a turn that no longer
                // exists. Discard it rather than overwriting
                // whatever the new turn has already measured.
                return
            }

            self.latestRenderCorrelation = result.correlation
            self.latestCorrelationLagMs = result.lagMs
            self.correlationInFlight = false
        }
    }

    /// Pure: takes explicit snapshots instead of touching instance
    /// state, so it can run safely on a background queue while the
    /// capture thread keeps mutating the live history arrays.
    private static func computeRenderCorrelation(
        rawCaptureFrame: [Float],
        renderHistory: [Float]
    ) -> (correlation: Float, lagMs: Int) {

        let capture24k =
            downsampleCaptureTo24k(
                rawCaptureFrame
            )

        guard !capture24k.isEmpty else {
            return (0, 0)
        }

        let windowSize =
            capture24k.count

        guard renderHistory.count >=
                windowSize
        else {
            return (0, 0)
        }

        // Search up to 250 ms into recent render history.
        let maximumLagSamples =
            min(
                6_000,
                renderHistory.count -
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
                renderHistory.count -
                lag

            let start =
                end -
                windowSize

            guard start >= 0,
                  end <=
                    renderHistory.count
            else {
                break
            }

            let renderWindow =
                renderHistory[
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

        let lagMs =
            Int(
                Double(bestLagSamples)
                / 24_000.0
                * 1000.0
            )

        return (bestCorrelation, lagMs)
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

        // Pre-existing gap: this wasn't being cleared, so a prior
        // speaking turn's render audio could still be searched
        // against by the next turn's correlation lookup.
        renderWaveformHistory.removeAll(
            keepingCapacity: true
        )

        latestRenderRMS = 0
        latestRenderCorrelation = 0
        latestCorrelationLagMs = 0

        correlationInFlight = false
        framesSinceLastCorrelationUpdate = 0
        resetGeneration += 1
        
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
