//
//  OllamaService.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 09/12/2023.
//

import Foundation
import OllamaKit
import Combine

class OllamaService: LLMService, @unchecked Sendable {
    static let shared = OllamaService()

    var ollamaKit: OllamaKit

    init() {
        ollamaKit = OllamaKit(baseURL: URL(string: "http://localhost:11434")!)
        initEndpoint()
    }

    func initEndpoint(url: String? = nil, bearerToken: String? = "okki") {
        let defaultUrl = "http://localhost:11434"
        let localStorageUrl = UserDefaults.standard.string(forKey: "ollamaUri")
        let bearerToken = UserDefaults.standard.string(forKey: "ollamaBearerToken")
        if var ollamaUrl = [localStorageUrl, defaultUrl].compactMap({$0}).filter({$0.count > 0}).first {
            if !ollamaUrl.contains("http") {
                ollamaUrl = "http://" + ollamaUrl
            }

            if let url = URL(string: ollamaUrl) {
                ollamaKit =  OllamaKit(baseURL: url, bearerToken: bearerToken)
                return
            }
        }
    }

    func getModels() async throws -> [LanguageModel]  {
        let response = try await ollamaKit.models()
        let models = response.models.map{
            LanguageModel(
                name: $0.name,
                provider: .ollama,
                imageSupport: $0.details.families?.contains(where: { $0 == "clip" || $0 == "mllama" }) ?? false
            )
        }
        return models
    }

    func reachable() async -> Bool {
        return await ollamaKit.reachable()
    }

    func chat(request: ChatRequest) -> AnyPublisher<any ChatResponse, Error> {
        let subject = PassthroughSubject<any ChatResponse, Error>()

        var okMessages: [OKChatRequestData.Message] = request.messages.map { message in
            OKChatRequestData.Message(
                role: OKChatRequestData.Message.Role(rawValue: message.role.rawValue) ?? .assistant,
                content: message.content,
                images: message.images ?? nil
            )
        }

        var okRequest = OKChatRequestData(model: request.model, messages: okMessages)
        if let temp = request.temperature {
            okRequest.options = OKCompletionOptions(temperature: Float(temp))
        }

        let cancellable = ollamaKit.chat(data: okRequest)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    subject.send(completion: .finished)
                case .failure(let error):
                    subject.send(completion: .failure(error))
                }
            }, receiveValue: { response in
                subject.send(OpenAIChatResponse(content: response.message?.content))
            })

        return subject
            .handleEvents(receiveCancel: {
                cancellable.cancel()
            })
            .eraseToAnyPublisher()
    }
}
