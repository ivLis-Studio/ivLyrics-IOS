import Foundation

struct OpenAIConnection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = "API"
    var baseUrl = "https://api.openai.com/v1"
    var apiKeys = ""
    var model = ""
    var enabled = true

    var isReady: Bool { enabled && !apiKeys.trimmed.isEmpty && !model.trimmed.isEmpty }
}
