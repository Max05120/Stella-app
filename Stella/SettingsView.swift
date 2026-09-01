//
//  SettingsView.swift
//  Stella
//
//  Created by Harish Maheshwaran on 29/08/26.
//


import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var backend: BackendManager
    @AppStorage("speakRepliesEnabled") private var speakRepliesEnabled = true
    
    var body: some View {
        Form {
            Section("Backend") {
                LabeledContent("Status", value: statusText)
                Button("Restart Backend") {
                    backend.stop()
                    backend.start()
                }
            }
            Section("About") {
                LabeledContent("Assistant", value: "Stella")
                LabeledContent("Version", value: "0.1")
            }
            Section("Voice") {
                Toggle("Speak Stella's replies", isOn: $speakRepliesEnabled)
            }
        }
        .padding(20)
        .frame(width: 380, height: 220)
    }
    
    private var statusText: String {
        switch backend.status {
        case .notStarted: return "Not started"
        case .starting: return "Starting..."
        case .ready: return "Running"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}
