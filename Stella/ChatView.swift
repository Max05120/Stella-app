import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    var sources: [Source] = []
    var toolsUsed: [String] = []

    enum Role { case user, assistant }
}

struct ChatView: View {

    let conversationId: String

    @EnvironmentObject private var backend: BackendManager

    @State private var input = ""
    @State private var messages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    private let api = APIClient()
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            if isLoading {
                proxy.scrollTo("loading-indicator", anchor: .bottom)
            } else if let lastId = messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {

            HStack {
                Text("✦ Stella").font(.headline)
                Spacer()
                Button {
                    Task { await clearConversation() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            if backend.status == .starting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Starting Stella...")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            } else if case .failed(let reason) = backend.status {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(reason).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { backend.start() }
                }
                .padding(.horizontal)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if isLoading {
                            HStack {
                                ProgressView()
                                Text("Thinking...").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .id("loading-indicator")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in scrollToBottom(proxy: proxy) }
                .onChange(of: isLoading) { _, _ in scrollToBottom(proxy: proxy) }
            }

            Divider()

            HStack {
                TextField("Talk to Stella...", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(
                    input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isLoading
                        || backend.status != .ready
                )
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 600)
        .overlay {
            Button("") { inputFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        }
        .onAppear { inputFocused = true }
        .task(id: conversationId) { await loadHistory() }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadHistory() async {
        messages = []
        guard let history = try? await api.getHistory(conversationId: conversationId) else { return }
        messages = history.map {
            ChatMessage(
                role: $0.role == "user" ? .user : .assistant,
                content: $0.content,
                sources: $0.sources,
                toolsUsed: $0.toolsUsed
            )
        }
        
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        input = ""
        isLoading = true

        Task {
            do {
                let response = try await api.chat(message: text, conversationId: conversationId)
                messages.append(ChatMessage(
                    role: .assistant,
                    content: response.answer,
                    sources: response.sources,
                    toolsUsed: response.toolsUsed
                ))
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func clearConversation() async {
        do {
            try await api.clearMemory(conversationId: conversationId)
            messages.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


struct MessageBubble: View {

    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 6) {

            HStack {
                if message.role == .assistant {
                    bubble
                    Spacer()
                } else {
                    Spacer()
                    bubble
                }
            }

            if message.role == .assistant && !message.toolsUsed.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.toolsUsed, id: \.self) { tool in
                        Label(toolLabel(tool), systemImage: toolIcon(tool))
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }

            if message.role == .assistant && !message.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(message.sources.enumerated()), id: \.offset) { _, source in
                            SourceCard(source: source)
                        }
                    }
                }
            }
        }
    }

    private var bubble: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: message.content,
                options: .init(interpretedSyntax: .full)
            ) {
                Text(attributed)
            } else {
                Text(message.content)
            }
        }
        .padding(10)
        .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 420, alignment: message.role == .assistant ? .leading : .trailing)
    }

    private func toolLabel(_ tool: String) -> String {
        switch tool {
        case "get_weather": return "Weather"
        case "web_search": return "Web search"
        case "search_knowledge_base": return "Your documents"
        default: return tool
        }
    }

    private func toolIcon(_ tool: String) -> String {
        switch tool {
        case "get_weather": return "cloud.sun"
        case "web_search": return "magnifyingglass"
        case "search_knowledge_base": return "doc.text.magnifyingglass"
        default: return "wrench"
        }
    }
}

struct SourceCard: View {
    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(source.source, systemImage: "doc.text")
                .font(.caption.bold())
                .lineLimit(1)
            if let page = source.page {
                Text("Page \(page)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(width: 140, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
