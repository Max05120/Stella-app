//
//  WhisperTestView.swift
//  Stella
//
//  Created by Harish Maheshwaran on 30/08/26.
//


import SwiftUI


struct WhisperTestView: View {

    @StateObject private var recorder =
        MicrophoneRecorder()

    @State private var whisper:
        WhisperTranscriber?

    @State private var transcript = ""

    @State private var status = "Loading Whisper..."

    var body: some View {

        VStack(spacing: 20) {

            Text("Stella Voice Test")
                .font(.title2.bold())

            Text(status)
                .foregroundStyle(.secondary)

            if recorder.isRecording {

                ProgressView(
                    value: Double(
                        min(recorder.level * 20, 1)
                    )
                )
                .frame(width: 240)
            }

            Text(transcript)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 80,
                    alignment: .topLeading
                )
                .padding()
                .background(.quaternary)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 12
                    )
                )

            Button(
                recorder.isRecording
                    ? "Stop & Transcribe"
                    : "Start Recording"
            ) {

                Task {
                    await toggleRecording()
                }
            }
            .buttonStyle(.borderedProminent)

        }
        .padding(30)
        .frame(
            width: 420,
            height: 300
        )
        .task {

            do {

                whisper =
                    try WhisperTranscriber()

                status = "Whisper ready"

            } catch {

                status =
                    "Whisper error: \(error.localizedDescription)"
            }
        }
    }
    
    private func toggleRecording() async {

        if recorder.isRecording {

            status = "Transcribing..."

            let samples = recorder.stop()

            guard let whisper else {
                return
            }

            do {

                let started = Date()

                let text = try await whisper.transcribe(
                    samples: samples
                )

                transcript = text

                let ms = Date()
                    .timeIntervalSince(started) * 1000

                status =
                    "Done — \(Int(ms)) ms"

            } catch {

                status =
                    "Error: \(error.localizedDescription)"
            }

        } else {

            transcript = ""

            do {

                try recorder.start()

                status = "Listening..."

            } catch {

                status =
                    "Mic error: \(error.localizedDescription)"
            }
        }
    }
}
