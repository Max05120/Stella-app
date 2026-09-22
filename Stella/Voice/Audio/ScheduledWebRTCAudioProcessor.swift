import Foundation
import AVFoundation

// Debug experiment: retain the existing APM, but serialize both streams using
// their audio host timestamps. This does not alter the engine or microphone tap.
protocol TimestampedAudioPreprocessor: AudioPreprocessor {
    func startSession()
    func submitCapture(
        _ samples: [Float], sampleRate: Double, hostTime: UInt64,
        completion: @escaping @Sendable ([AECProcessedFrame]) -> Void
    )
    func submitRender(_ samples: [Float], sampleRate: Double, hostTime: UInt64)
}

final class ScheduledWebRTCAudioProcessor:
    TimestampedAudioPreprocessor, @unchecked Sendable {

    private struct Capture: Sendable {
        let samples: [Float]
        let start: Double
        let arrival: Double
        let completion: @Sendable ([AECProcessedFrame]) -> Void
        var end: Double { start + Double(samples.count) / 48_000 }
    }
    private struct Render: Sendable {
        let samples: [Float]
        let start: Double
    }

    private let processor: WebRTCAudioProcessor
    private let worker = DispatchQueue(
        label: "com.stella.aec.timestamp-scheduler", qos: .userInitiated
    )
    private var timer: DispatchSourceTimer?

    // Only ingress/lifecycle fields use this small lock. APM work never runs
    // while this lock is held. No waiting for render or disk I/O on a tap.
    private let gate = NSLock()
    private var accepting = false
    private var queuedJobs = 0
    // Protected by gate.
    private var pendingRenderJobs = 0

    // Accessed only on worker.
    private var maxRenderQueueMs: Double = 0
    private var maxCaptureQueueMs: Double = 0
    private var maxAPMBatchMs: Double = 0
    private var overloadReported = false

    // All remaining mutable state is confined to worker.
    private var running = false
    private var fault: String?
    private var captureQueue: [Capture] = []
    private var renderQueue: [Render] = []
    private var nextCaptureTime: Double?
    private var nextRenderTime: Double?
    private var renderThrough: Double?
    private var lastCaptureStart = -Double.infinity
    private var captureFrames = 0
    private var renderFrames = 0
    private var timeouts = 0
    private var lateRenderFrames = 0
    private var shutdownDrains = 0
    private var maxWait: Double = 0
    private var lastReport: Double = 0

    // Bounded additional wait for another tap callback. This is NOT an
    // acoustic delay estimate. It may add up to 150 ms to capture delivery.
    private let maximumWait = 0.150
    private let tolerance = 0.001

    init(processor: WebRTCAudioProcessor) {
        self.processor = processor
        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now() + .milliseconds(10),
                        repeating: .milliseconds(10))
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        timer = source
    }

    deinit { timer?.cancel() }

    // Call only at session start, before AVAudioEngine starts. Never on worker.
    func startSession() {
        gate.lock()
        accepting = false
        gate.unlock()
        worker.sync {
            captureQueue.removeAll(keepingCapacity: true)
            renderQueue.removeAll(keepingCapacity: true)
            nextCaptureTime = nil
            nextRenderTime = nil
            renderThrough = nil
            lastCaptureStart = -Double.infinity
            captureFrames = 0
            renderFrames = 0
            timeouts = 0
            lateRenderFrames = 0
            shutdownDrains = 0
            maxWait = 0
            maxRenderQueueMs = 0
            maxCaptureQueueMs = 0
            maxAPMBatchMs = 0
            lastReport = ProcessInfo.processInfo.systemUptime
            fault = nil
            processor.reset()
            running = true
        }
        gate.lock()
        overloadReported = false
        accepting = true
        gate.unlock()
        print("[AEC-SCHED] started: timestamp order, max added wait 150 ms")
    }

    func submitCapture(
        _ samples: [Float], sampleRate: Double, hostTime: UInt64,
        completion: @escaping @Sendable ([AECProcessedFrame]) -> Void
    ) {
        let arrival = ProcessInfo.processInfo.systemUptime
        enqueue(kind: "capture") { [self] in
            guard validate(samples, rate: sampleRate, expectedRate: 48_000,
                           frameSize: 480, hostTime: hostTime) else { return }
            let start = AVAudioTime.seconds(forHostTime: hostTime)
            guard checkContinuity(start, expected: nextCaptureTime,
                                  stream: "capture") else { return }
            nextCaptureTime = start + Double(samples.count) / 48_000
            let pendingSamples = captureQueue.reduce(0) { $0 + $1.samples.count }
            guard pendingSamples + samples.count <= 48_000 else {
                fail("capture backlog exceeds one second")
                return
            }
            captureQueue.append(Capture(samples: samples, start: start,
                                        arrival: arrival, completion: completion))
            drain()
        }
    }

    func submitRender(_ samples: [Float], sampleRate: Double, hostTime: UInt64) {
        enqueue(kind: "render")  { [self] in
            guard validate(samples, rate: sampleRate, expectedRate: 24_000,
                           frameSize: 240, hostTime: hostTime) else { return }
            let start = AVAudioTime.seconds(forHostTime: hostTime)
            guard checkContinuity(start, expected: nextRenderTime,
                                  stream: "render") else { return }
            nextRenderTime = start + Double(samples.count) / 24_000
            renderThrough = nextRenderTime
            for offset in stride(from: 0, to: samples.count, by: 240) {
                let stamp = start + Double(offset) / 24_000
                if stamp <= lastCaptureStart + 0.000001 {
                    // A timeout previously allowed capture to advance. Never
                    // feed this stale reference later as if it were current.
                    lateRenderFrames += 1
                    continue
                }
                renderQueue.append(Render(
                    samples: Array(samples[offset..<(offset + 240)]), start: stamp
                ))
            }
            guard renderQueue.count <= 100 else {
                fail("render backlog exceeds one second")
                return
            }
            drain()
        }
    }

    // AudioPreprocessor's untimestamped methods are intentionally forbidden
    // for this wrapper. Legacy smoke tests should use the underlying processor.
    func processCapture(_ samples: [Float]) -> [AECProcessedFrame] {
        enqueue { [self] in fail("untimestamped capture call: check integration") }
        return []
    }
    func processRender(_ samples: [Float]) {
        enqueue { [self] in fail("untimestamped render call: check integration") }
    }

    // Called by AudioCaptureEngine.stop AFTER stopping its engine. The queue
    // barrier ensures pending diagnostics finish before recorder.finish().
    // Do not call reset from a worker completion, or during a speaking turn.
    func reset() {
        gate.lock()
        accepting = false
        gate.unlock()
        worker.sync {
            if running {
                drain(force: true)
                report(final: true)
            }
            running = false
            captureQueue.removeAll(keepingCapacity: true)
            renderQueue.removeAll(keepingCapacity: true)
            processor.reset()
        }
    }

    private func enqueue(
        kind: String = "other",
        _ operation: @escaping @Sendable () -> Void
    ) {
        let submittedAt = ProcessInfo.processInfo.systemUptime

        gate.lock()

        guard accepting else {
            gate.unlock()
            return
        }

        guard queuedJobs < 32 else {
            accepting = false
            let announce = !overloadReported
            overloadReported = true

            if announce {
                worker.async { [self] in
                    fail("ingress overload: session invalid")
                }
            }

            gate.unlock()
            return
        }

        queuedJobs += 1

        if kind == "render" {
            pendingRenderJobs += 1
        }

        worker.async { [self] in
            let queueMs =
                (ProcessInfo.processInfo.systemUptime - submittedAt) * 1000

            gate.lock()
            if kind == "render" {
                pendingRenderJobs -= 1
            }
            gate.unlock()

            defer {
                gate.lock()
                queuedJobs -= 1
                gate.unlock()
            }

            guard running, fault == nil else { return }

            if kind == "render" {
                maxRenderQueueMs = max(maxRenderQueueMs, queueMs)
            } else if kind == "capture" {
                maxCaptureQueueMs = max(maxCaptureQueueMs, queueMs)
            }

            operation()
        }

        gate.unlock()
    }

    private func validate(
        _ samples: [Float], rate: Double, expectedRate: Double,
        frameSize: Int, hostTime: UInt64
    ) -> Bool {
        // Deliberately scoped to the measured experiment: all observed taps
        // contained an integral number of 10 ms frames. Never silently truncate
        // a different callback size; stop the experiment and report it.
        guard hostTime != 0, rate == expectedRate,
              !samples.isEmpty, samples.count % frameSize == 0,
              samples.count <= frameSize * 20 else {
            fail("unsupported timestamp/rate/block: rate=\(rate) samples=\(samples.count)")
            return false
        }
        return true
    }

    private func checkContinuity(
        _ actual: Double, expected: Double?, stream: String
    ) -> Bool {
        if let expected, abs(actual - expected) > tolerance {
            fail("\(stream) timestamp gap/reversal: \((actual - expected) * 1000) ms")
            return false
        }
        return true
    }

    private func drain(force: Bool = false) {
        guard running, fault == nil else { return }
        while let packet = captureQueue.first {
            let wait = ProcessInfo.processInfo.systemUptime - packet.arrival
            let ready = (renderThrough ?? -Double.infinity) >= packet.end - 0.000001
            guard ready || force || wait >= maximumWait else { break }

            // Before declaring a timeout, let accepted render jobs execute.
            // Breaking returns control to the serial worker queue.
            // Their submitRender operations call drain() again.
            if !ready && !force {
                gate.lock()
                let renderWorkIsWaiting = pendingRenderJobs > 0
                gate.unlock()

                if renderWorkIsWaiting {
                    break
                }
            }

            captureQueue.removeFirst()
            if !ready {
                if force {
                    shutdownDrains += 1
                } else {
                    timeouts += 1

                    gate.lock()
                    let pendingRender = pendingRenderJobs
                    let outstandingJobs = queuedJobs
                    gate.unlock()

                    let referenceBehindMs: String
                    if let through = renderThrough {
                        referenceBehindMs = String(
                            format: "%.1f",
                            max(0, packet.end - through) * 1000
                        )
                    } else {
                        referenceBehindMs = "no-reference"
                    }

                    print(String(
                        format:
                            "[AEC-SCHED-TIMEOUT] waitMs=%.1f " +
                            "pendingRender=%d outstandingJobs=%d referenceBehindMs=%@",
                        wait * 1000,
                        pendingRender,
                        outstandingJobs,
                        referenceBehindMs
                    ))
                }
            }
            maxWait = max(maxWait, wait)
            var output: [AECProcessedFrame] = []
            output.reserveCapacity(packet.samples.count / 480)
            let apmBatchStarted = ProcessInfo.processInfo.systemUptime
            for offset in stride(from: 0, to: packet.samples.count, by: 480) {
                let captureTime = packet.start + Double(offset) / 48_000
                while let reference = renderQueue.first,
                      reference.start <= captureTime + 0.000001 {
                    renderQueue.removeFirst()
                    processor.processRender(reference.samples)
                    renderFrames += 1
                }
                let frame = Array(packet.samples[offset..<(offset + 480)])
                let result = processor.processCapture(frame)
                guard result.count == 1, result[0].samples.count == 480 else {
                    fail("APM returned unexpected 10 ms capture shape")
                    return
                }
                output.append(contentsOf: result)
                captureFrames += 1
                lastCaptureStart = captureTime
            }
            maxAPMBatchMs = max(
                maxAPMBatchMs,
                (ProcessInfo.processInfo.systemUptime - apmBatchStarted) * 1000
            )
            // Keep the existing 100 ms listener block size in this experiment.
            // Only the APM call ordering changes; TurnDetector still receives
            // the same sample count per callback, in original capture order.
            packet.completion(output)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReport >= 5 {
            report(final: false)
            lastReport = now
        }
    }

    private func fail(_ message: String) {
        guard fault == nil else { return }
        fault = message
        captureQueue.removeAll(keepingCapacity: true)
        renderQueue.removeAll(keepingCapacity: true)
        print("[AEC-SCHED] FAULT: \(message). Stop this test session.")
    }

    private func report(final: Bool) {
        print(String(
            format: "[AEC-SCHED] %@ capture10ms=%d render10ms=%d timeouts=%d lateRender=%d shutdownDrains=%d maxWaitMs=%.1f fault=%@",
            final ? "FINAL" : "stats", captureFrames, renderFrames,
            timeouts, lateRenderFrames, shutdownDrains, maxWait * 1000,
            fault ?? "none"
        ))
        print(String(
            format:
                "[AEC-SCHED-TIMING] %@ maxCaptureQueueMs=%.1f " +
                "maxRenderQueueMs=%.1f maxAPMBatchMs=%.1f",
            final ? "FINAL" : "stats",
            maxCaptureQueueMs,
            maxRenderQueueMs,
            maxAPMBatchMs
        ))
    }
}
