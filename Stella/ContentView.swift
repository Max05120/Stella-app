import SwiftUI

struct ContentView: View {

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedConversationId: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(selectedConversationId: $selectedConversationId)
        } detail: {
            if let conversationId = selectedConversationId {
                ChatView(conversationId: conversationId)
            } else {
                ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 600)
    }
}
