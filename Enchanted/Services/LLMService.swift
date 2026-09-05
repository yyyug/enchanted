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
    }

    let role: Role
    let content: String
    let images: [String]?
}

struct ChatRequest {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
}

protocol ChatResponse {
    var content: String? { get }
}

protocol LLMService: AnyObject {
    func getModels() async throws -> [LanguageModel]
    func reachable() async -> Bool
    func chat(request: ChatRequest) -> AnyPublisher<any ChatResponse, Error>
}
