//
//  AECDiagnosticRecorder.swift
//  Stella
//
//  Created by Harish Maheshwaran on 22/09/26.
//


import Foundation
import AVFoundation
import Darwin

final class AECDiagnosticRecorder: @unchecked Sendable {
    static let shared = AECDiagnosticRecorder()

    private struct Header: Codable, Sendable {
        let kind: String
        let hostTicks: UInt64?
        let hostSeconds: Double?
        let callbackHostSeconds: Double
        let sampleTime: Int64?
        let sampleRate: Double
        let sourceOffset: Int
        let cleanOffset: Int?
        let sampleCount: Int
        let cleanCount: Int
    }

    private struct Packet: Sendable {
        let header: Header
        let samples: [Float]
        let clean: [Float]
    }

    private struct Summary: Codable, Sendable {
        let label: String
        let droppedPackets: Int
        let limitReached: Bool
        let captureSamplesSubmitted: Int
        let cleanSamplesSubmitted: Int
        let renderSamplesSubmitted: Int
        let invalidHostTimestamps: Int
        let formatMismatch: Bool
    }

    private let lock = NSLock()
    private let writer = DispatchQueue(
        label: "com.stella.aec.diagnostic-export", qos: .utility
    )
    private var active = false
    private var exporting = false
    private var packets: [Packet] = []
    private var label = ""
    private var started: Double = 0
    private var bytes = 0
    private var dropped = 0
    private var limited = false
    private var invalidTimes = 0
    private var wrongFormat = false
    private var rawOffset = 0
    private var cleanOffset = 0
    private var renderOffset = 0

    private init() {}

    // Call on the main thread before starting the conversation engine.
    func start(label: String) {
        lock.lock()
        guard !active, !exporting else {
            lock.unlock()
            print("[AEC-DUMP] already recording or exporting")
            return
        }
        packets.removeAll(keepingCapacity: true)
        packets.reserveCapacity(30_000)
        self.label = label
        started = ProcessInfo.processInfo.systemUptime
        bytes = 0
        dropped = 0
        limited = false
        invalidTimes = 0
        wrongFormat = false
        rawOffset = 0
        cleanOffset = 0
        renderOffset = 0
        active = true
        lock.unlock()
        print("[AEC-DUMP] recording: \(label), maximum 180 seconds")
    }

    func capture(
        raw: [Float], clean: [Float],
        sampleRate: Double, time: AVAudioTime
    ) {
        record(kind: "capture", samples: raw, clean: clean,
               sampleRate: sampleRate, time: time)
    }

    func render(
        samples: [Float], sampleRate: Double, time: AVAudioTime
    ) {
        record(kind: "render", samples: samples, clean: [],
               sampleRate: sampleRate, time: time)
    }

    private func record(
        kind: String, samples: [Float], clean: [Float],
        sampleRate: Double, time: AVAudioTime
    ) {
        // All fields below are protected by this lock. No disk I/O here.
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }

        let isCapture = kind == "capture"
        let sourceStart = isCapture ? rawOffset : renderOffset
        let cleanStart: Int? = isCapture ? cleanOffset : nil
        if isCapture {
            rawOffset += samples.count
            cleanOffset += clean.count
        } else {
            renderOffset += samples.count
        }

        // The current processor assumes 48 kHz capture and 24 kHz render.
        // Refuse to disguise a different device format as those rates.
        guard sampleRate == (isCapture ? 48_000 : 24_000) else {
            wrongFormat = true
            dropped += 1
            return
        }

        let packetBytes = (samples.count + clean.count) * MemoryLayout<Float>.size
        guard ProcessInfo.processInfo.systemUptime - started <= 180,
              bytes + packetBytes <= 96 * 1024 * 1024,
              packets.count < 30_000 else {
            limited = true
            dropped += 1
            return
        }

        let ticks: UInt64? = time.isHostTimeValid ? time.hostTime : nil
        if ticks == nil { invalidTimes += 1 }
        let header = Header(
            kind: kind,
            hostTicks: ticks,
            hostSeconds: ticks.map { AVAudioTime.seconds(forHostTime: $0) },
            callbackHostSeconds: AVAudioTime.seconds(
                forHostTime: mach_absolute_time()
            ),
            sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
            sampleRate: sampleRate,
            sourceOffset: sourceStart,
            cleanOffset: cleanStart,
            sampleCount: samples.count,
            cleanCount: clean.count
        )
        packets.append(Packet(header: header, samples: samples, clean: clean))
        bytes += packetBytes
    }

    // Call after the conversation engine and output have stopped.
    func finish() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        exporting = true
        let savedPackets = packets
        packets = []
        let summary = Summary(
            label: label, droppedPackets: dropped, limitReached: limited,
            captureSamplesSubmitted: rawOffset,
            cleanSamplesSubmitted: cleanOffset,
            renderSamplesSubmitted: renderOffset,
            invalidHostTimestamps: invalidTimes,
            formatMismatch: wrongFormat
        )
        lock.unlock()

        writer.async { [self] in
            defer {
                lock.lock()
                exporting = false
                lock.unlock()
            }
            do {
                let root = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                )[0].appendingPathComponent("Stella/AECDiagnostics", isDirectory: true)
                let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true
                )
                try Self.export(savedPackets, summary: summary, to: folder)
                print("[AEC-DUMP] saved: \(folder.path)")
                print("[AEC-DUMP] dropped=\(summary.droppedPackets) " +
                      "formatMismatch=\(summary.formatMismatch) " +
                      "invalidHostTimes=\(summary.invalidHostTimestamps)")
            } catch {
                print("[AEC-DUMP] export failed: \(error.localizedDescription)")
            }
        }
    }

    private static func export(
        _ packets: [Packet], summary: Summary, to folder: URL
    ) throws {
        let micFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 1, interleaved: false
        )!
        let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
            channels: 1, interleaved: false
        )!
        let rawFile = try AVAudioFile(
            forWriting: folder.appendingPathComponent("raw-mic.caf"),
            settings: micFormat.settings
        )
        let cleanFile = try AVAudioFile(
            forWriting: folder.appendingPathComponent("clean-mic.caf"),
            settings: micFormat.settings
        )
        let renderFile = try AVAudioFile(
            forWriting: folder.appendingPathComponent("render.caf"),
            settings: renderFormat.settings
        )

        let encoder = JSONEncoder()
        var timeline = Data()
        for packet in packets {
            if packet.header.kind == "capture" {
                try append(packet.samples, to: rawFile)
                try append(packet.clean, to: cleanFile)
            } else {
                try append(packet.samples, to: renderFile)
            }
            timeline.append(try encoder.encode(packet.header))
            timeline.append(0x0A)
        }
        try timeline.write(to: folder.appendingPathComponent("timeline.jsonl"))
        try encoder.encode(summary).write(
            to: folder.appendingPathComponent("summary.json")
        )
        // AVAudioFile instances close when this function returns.
    }

    private static func append(_ samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let destination = buffer.floatChannelData?[0] else {
            throw NSError(domain: "AECDiagnosticRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PCM allocation failed"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}

