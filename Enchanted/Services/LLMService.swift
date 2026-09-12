//
//  LLMService.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 09/12/2023.
//

import Foundation
import Combine

struct ChatMessage {
    enum Role: String {
        case system
        case user
        case assistant
        case tool
    }

    let role: Role
    let content: String
    let images: [String]?
    let toolCallId: String?
    let toolCalls: [ChatToolCall]?

    init(role: Role, content: String, images: [String]? = nil, toolCallId: String? = nil, toolCalls: [ChatToolCall]? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }
}

struct ChatToolCall: Codable {
    let id: String
    let type: String?
    let function: ChatToolCallFunction

    enum CodingKeys: String, CodingKey {
        case id, type, function
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        function = try container.decode(ChatToolCallFunction.self, forKey: .function)
    }
}

struct ChatToolCallFunction: Codable {
    let name: String
    let arguments: String
}

struct ChatRequest {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
}

struct ChatCompletionMessage {
    let content: String?
    let toolCalls: [ChatToolCall]
}

protocol ChatResponse {
    var content: String? { get }
}

protocol LLMService: AnyObject {
    func getModels() async throws -> [LanguageModel]
    func reachable() async -> Bool
    func chat(request: ChatRequest) -> AnyPublisher<any ChatResponse, Error>
}

protocol ChatCompletionProviding: LLMService {
    func chatCompletion(messages: [ChatMessage], model: String, temperature: Double?, tools: [[String: Any]]?) async throws -> ChatCompletionMessage
}
