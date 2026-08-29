//
//  ConversationListView.swift
//  Stella
//
//  Created by Harish Maheshwaran on 29/08/26.
//


import SwiftUI

struct ConversationListView: View {

    @Binding var selectedConversationId: String?
    @State private var conversations: [Conversation] = []
    private let api = APIClient()

    var body: some View {
        List(selection: $selectedConversationId) {
            ForEach(conversations) { convo in
                Text(convo.title).lineLimit(1).tag(convo.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await newConversation() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New conversation")
            }
        }
        .task { await loadConversations() }
    }

    private func loadConversations() async {
        guard let list = try? await api.listConversations() else { return }
        conversations = list
        if list.isEmpty {
            await newConversation()
        } else if selectedConversationId == nil {
            selectedConversationId = list.first?.id
        }
    }

    private func newConversation() async {
        if let convo = try? await api.createConversation() {
            conversations.insert(convo, at: 0)
            selectedConversationId = convo.id
        }
    }
}
