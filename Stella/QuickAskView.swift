//
//  QuickAskView.swift
//  Stella
//
//  Created by Harish Maheshwaran on 29/08/26.
//


import SwiftUI

struct QuickAskView: View {

    @ObservedObject var backend: BackendManager
    var onDismiss: () -> Void

    @State private var input = ""
    @State private var answer: String?
    @State private var isLoading = false
    @FocusState private var focused: Bool

    private let api = APIClient()
    private let conversationId = QuickAskView.loadOrCreateConversationId()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                TextField("Ask Stella anything...", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { ask() }
                if isLoading { ProgressView().controlSize(.small) }
            }

            if let answer {
                Divider()
                ScrollView {
                    Text(answer)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { focused = true }
        .onExitCommand { onDismiss() }
    }

    private func ask() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, backend.status == .ready else { return }

        isLoading = true
        Task {
            do {
                let response = try await api.chat(message: question, conversationId: conversationId)
                answer = response.answer
            } catch {
                answer = "Something went wrong: \(error.localizedDescription)"
            }
            isLoading = false
            input = ""
        }
    }

    private static func loadOrCreateConversationId() -> String {
        let key = "quickAskConversationId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}