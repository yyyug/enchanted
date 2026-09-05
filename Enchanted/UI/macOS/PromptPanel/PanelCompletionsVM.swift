//
//  PromptPanelVM.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 29/02/2024.
//

import SwiftUI
import Combine

@Observable
final class CompletionsPanelVM {
    var selectedText: String?
    var onReceiveText: (String) -> ()
    var messageResponse: String = ""
    var isReady = false
    let sentenceQueue = AsyncQueue<String>()
    private var generation: AnyCancellable?
    private var currentMessageBuffer: String = ""


    init(onReceiveText: @escaping (String) -> Void = {_ in}) {
        self.onReceiveText = onReceiveText
    }

    static func constructPrompt(completion: CompletionInstructionSD, selectedText: String) -> String {
        var prompt = completion.instruction

        if prompt.contains("{{text}}") {
            prompt.replace("{{text}}", with: selectedText)
        } else {
            prompt += " " + selectedText
        }

        return prompt
    }

    private func getService(for provider: ModelProvider?) -> LLMService {
        switch provider {
        case .openAI:
            return OpenAIService.shared
        case .ollama, .none:
            return OllamaService.shared
        }
    }

    @MainActor
    func sendPrompt(completion: CompletionInstructionSD, model: LanguageModelSD)  {
        guard let selectedText = selectedText, !isReady else { return }
        let prompt = CompletionsPanelVM.constructPrompt(completion: completion, selectedText: selectedText)

        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: prompt, images: nil)
        ]
        let request = ChatRequest(model: model.name, messages: messages, temperature: completion.modelTemperature.map(Double.init) ?? 0.8)
        currentMessageBuffer = ""
        messageResponse = ""

        let service = getService(for: model.modelProvider)

        print("request", messages)
        Task {
            if await service.reachable() {
                generation = service.chat(request: request)
                    .sink(receiveCompletion: { [weak self] completion in
                        switch completion {
                        case .finished:
                            self?.handleComplete()
                        case .failure(let error):
                            self?.handleError(error.localizedDescription)
                        }
                    }, receiveValue: { [weak self] response in
                        self?.handleReceive(response)
                    })
            } else {
                self.handleError("Server unreachable")
            }
        }
    }

    @MainActor
    private func handleReceive(_ response: any ChatResponse)  {
        Task {
            if let responseContent = response.content {
                await sentenceQueue.enqueue(responseContent)
                self.messageResponse = self.messageResponse + responseContent
            }
        }
    }

    @MainActor
    private func handleError(_ errorMessage: String) {
        print("error \(errorMessage)")
    }

    @MainActor
    private func handleComplete() {
        print("model response ", self.messageResponse)
    }

    @MainActor
    func cancel() {
        generation?.cancel()
    }
}
