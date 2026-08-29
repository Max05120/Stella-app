import Foundation

struct ChatRequest: Codable {
    let message: String
    let conversationId: String
    enum CodingKeys: String, CodingKey {
        case message
        case conversationId = "conversation_id"
    }
}

struct ChatResponse: Codable {
    let answer: String
    let searchQuery: String
    let sources: [Source]
    let toolsUsed: [String]
    enum CodingKeys: String, CodingKey {
        case answer
        case searchQuery = "search_query"
        case sources
        case toolsUsed = "tools_used"
    }
}

struct Source: Codable {
    let source: String
    let page: Int?
    let text: String?
}

struct Conversation: Identifiable, Codable {
    let id: String
    let title: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
    }
}

struct HistoryMessage: Codable {
    let role: String
    let content: String
    let sources: [Source]
    let toolsUsed: [String]
    enum CodingKeys: String, CodingKey {
        case role, content, sources
        case toolsUsed = "tools_used"
    }
}

private struct EmptyBody: Encodable {}

final class APIClient {

    private let baseURL = "http://127.0.0.1:8000"

    func chat(message: String, conversationId: String) async throws -> ChatResponse {
        try await post("/chat", body: ChatRequest(message: message, conversationId: conversationId))
    }

    func clearMemory(conversationId: String) async throws {
        guard let url = URL(string: "\(baseURL)/memory/clear?conversation_id=\(conversationId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    func listConversations() async throws -> [Conversation] {
        try await get("/conversations")
    }

    func createConversation() async throws -> Conversation {
        try await post("/conversations", body: EmptyBody())
    }

    func getHistory(conversationId: String) async throws -> [HistoryMessage] {
        try await get("/conversations/\(conversationId)/history")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.checkStatus(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw NSError(domain: "Stella", code: 0,
                userInfo: [NSLocalizedDescriptionKey: detail ?? "Server error"])
        }
    }
}
