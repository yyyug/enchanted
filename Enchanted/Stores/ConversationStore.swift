//
//  ChatsStore.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import SwiftData
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

@Observable
final class ConversationStore: Sendable {
    static let shared = ConversationStore(swiftDataService: SwiftDataService.shared)

    private var swiftDataService: SwiftDataService
    private var generation: AnyCancellable?

    /// For some reason (SwiftUI bug / too frequent UI updates) updating UI for each stream message sometimes freezes the UI.
    /// Throttling UI updates seem to fix the issue.
    private var currentMessageBuffer: String = ""
#if os(macOS)
    private let throttler = Throttler(delay: 0.1)
#else
    private let throttler = Throttler(delay: 0.1)
#endif

    @MainActor var conversationState: ConversationState = .completed
    @MainActor var conversations: [ConversationSD] = []
    @MainActor var selectedConversation: ConversationSD?
    @MainActor var messages: [MessageSD] = []

    private var agenticTask: Task<Void, Never>?

    init(swiftDataService: SwiftDataService) {
        self.swiftDataService = swiftDataService
    }

    private func getService(for provider: ModelProvider?) -> LLMService {
        switch provider {
        case .openAI:
            return OpenAIService.shared
        case .ollama, .none:
            return OllamaService.shared
        }
    }

    /// Combines the global system prompt with any per-server prompts from
    /// enabled MCP servers.
    @MainActor
    private static func combinedSystemPrompt(_ base: String) -> String {
        var parts: [String] = []
        if !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(base)
        }
        parts.append(contentsOf: MCPServerStore.shared.enabledSystemPrompts)
        return parts.joined(separator: "\n\n")
    }

    /// Keeps the screen awake while a response is being generated.
    @MainActor
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
    
    func loadConversations() async throws {
        print("loading conversations")
        let fetchedConversations = try await swiftDataService.fetchConversations()
        DispatchQueue.main.async {
            self.conversations = fetchedConversations
        }
        print("loaded conversations")
    }
    
    func deleteAllConversations() {
        Task {
            DispatchQueue.main.async { [weak self] in
                self?.messages = []
                self?.selectedConversation = nil
            }
            try? await swiftDataService.deleteConversations()
            try? await swiftDataService.deleteMessages()
            try? await loadConversations()
        }
    }
    
    func deleteDailyConversations(_ date: Date) {
        Task {
            DispatchQueue.main.async { [self] in
                selectedConversation = nil
                messages = []
            }
            try? await swiftDataService.deleteConversations()
            try? await loadConversations()
        }
    }
    
    
    func create(_ conversation: ConversationSD) async throws {
        try await swiftDataService.createConversation(conversation)
    }
    
    func reloadConversation(_ conversation: ConversationSD) async throws {
        let (messages, selectedConversation) = try await (
            swiftDataService.fetchMessages(conversation.id),
            swiftDataService.getConversation(conversation.id)
        )
        
        DispatchQueue.main.async {
                self.messages = messages
                self.selectedConversation = selectedConversation
        }
    }
    
    func selectConversation(_ conversation: ConversationSD) async throws {
        try await reloadConversation(conversation)
    }
    
    func delete(_ conversation: ConversationSD) async throws {
        try await swiftDataService.deleteConversation(conversation)
        let fetchedConversations = try await swiftDataService.fetchConversations()
        DispatchQueue.main.async {
            self.selectedConversation = nil
            self.conversations = fetchedConversations
        }
    }
    
    @MainActor func stopGenerate() {
        generation?.cancel()
        agenticTask?.cancel()
        agenticTask = nil
        Task {
            await MCPServerStore.shared.cancelToolExecution()
        }
        handleComplete()
        setIdleTimerDisabled(false)
        withAnimation {
            conversationState = .completed
        }
    }

    /// Removes a single message from the conversation (and storage).
    @MainActor
    func deleteMessage(_ message: MessageSD) {
        messages.removeAll { $0.id == message.id }
        let conversation = selectedConversation
        Task(priority: .background) {
            try? await self.swiftDataService.deleteMessage(message)
            if let conversation {
                try? await self.reloadConversation(conversation)
                try? await self.loadConversations()
            }
        }
    }

    /// Re-runs the last user prompt, replacing the previous assistant reply.
    @MainActor
    func regenerateResponse(model: LanguageModelSD, systemPrompt: String) {
        guard let lastUser = messages.last(where: { $0.role == "user" }) else { return }
        let image = lastUser.image.flatMap { Image(data: $0) }
        sendPrompt(
            userPrompt: lastUser.content,
            model: model,
            image: image,
            systemPrompt: systemPrompt,
            trimmingMessageId: lastUser.id.uuidString
        )
    }
    
    @MainActor
    func sendPrompt(userPrompt: String, model: LanguageModelSD, image: Image? = nil, systemPrompt: String = "", trimmingMessageId: String? = nil) {
        guard userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return }

        let conversation = selectedConversation ?? ConversationSD(name: userPrompt)
        conversation.updatedAt = Date.now
        conversation.model = model

        print("model", model.name)
        print("conversation", conversation.name)

        /// trim conversation if on edit mode
        if let trimmingMessageId = trimmingMessageId {
            conversation.messages = conversation.messages
                .sorted{$0.createdAt < $1.createdAt}
                .prefix(while: {$0.id.uuidString != trimmingMessageId})
        }

        /// add system prompt to very first message in the conversation
        let combinedSystemPrompt = Self.combinedSystemPrompt(systemPrompt)
        if !combinedSystemPrompt.isEmpty && conversation.messages.isEmpty {
            let systemMessage = MessageSD(content: combinedSystemPrompt, role: "system")
            systemMessage.conversation = conversation
        }

        /// construct new message
        let userMessage = MessageSD(content: userPrompt, role: "user", image: image?.render()?.compressImageData())
        userMessage.conversation = conversation

        /// prepare message history
        var messageHistory = conversation.messages
            .sorted{$0.createdAt < $1.createdAt}
            .map{ChatMessage(role: ChatMessage.Role(rawValue: $0.role) ?? .assistant, content: $0.content, images: nil)}


        print(messageHistory.map({$0.content}))

        /// attach selected image to the last Message
        if let image = image?.render() {
            if let lastMessage = messageHistory.popLast() {
                let imagesBase64: [String] = [image.convertImageToBase64String()]
                let messageWithImage = ChatMessage(role: lastMessage.role, content: lastMessage.content, images: imagesBase64)
                messageHistory.append(messageWithImage)
            }
        }

        let assistantMessage = MessageSD(content: "", role: "assistant")
        assistantMessage.conversation = conversation

        conversationState = .loading()
        setIdleTimerDisabled(true)

        let service = getService(for: model.modelProvider)
        let chatRequest = ChatRequest(model: model.name, messages: messageHistory, temperature: 0)

        Task {
            try await swiftDataService.updateConversation(conversation)
            try await swiftDataService.createMessage(userMessage)
            try await swiftDataService.createMessage(assistantMessage)
            try await reloadConversation(conversation)
            try? await loadConversations()

            if await service.reachable() {
                let mcpStore = MCPServerStore.shared
                mcpStore.samplingModelName = model.name
                if mcpStore.hasEnabledServers {
                    await mcpStore.connectAll()
                }
                let tools = mcpStore.availableTools

                if !tools.isEmpty, let agenticService = service as? any ChatCompletionProviding {
                    agenticTask = Task { @MainActor in
                        await runAgenticLoop(
                            service: agenticService,
                            initialMessages: messageHistory,
                            model: model.name,
                            temperature: 0,
                            tools: tools
                        )
                    }
                } else {
                    DispatchQueue.global(qos: .background).async {
                        self.generation = service.chat(request: chatRequest)
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

                    }
                }
            } else {
                self.handleError("Server unreachable")
            }
        }
    }
    
    @MainActor
    private func handleReceive(_ response: any ChatResponse)  {
        if messages.isEmpty { return }

        if let responseContent = response.content {
            currentMessageBuffer = currentMessageBuffer + responseContent

            throttler.throttle { [weak self] in
                guard let self = self else { return }
                let lastIndex = self.messages.count - 1
                self.messages[lastIndex].content.append(currentMessageBuffer)
                currentMessageBuffer = ""
            }
        }
    }
    
    @MainActor
    private func handleError(_ errorMessage: String) {
        guard let lastMesasge = messages.last else { return }
        lastMesasge.error = true
        lastMesasge.done = false
        lastMesasge.errorMessage = errorMessage
        
        Task(priority: .background) {
            try? await swiftDataService.updateMessage(lastMesasge)
        }
        
        withAnimation {
            conversationState = .error(message: errorMessage)
        }
        setIdleTimerDisabled(false)
    }
    
    @MainActor
    private func handleComplete() {
        guard let lastMesasge = messages.last else { return }
        lastMesasge.error = false
        lastMesasge.done = true
        lastMesasge.errorMessage = nil
        
        Task(priority: .background) {
            try await self.swiftDataService.updateMessage(lastMesasge)
        }
        
        withAnimation {
            conversationState = .completed
        }
        setIdleTimerDisabled(false)
    }

    // MARK: - MCP Agentic Loop

    @MainActor
    private func runAgenticLoop(
        service: any ChatCompletionProviding,
        initialMessages: [ChatMessage],
        model: String,
        temperature: Double?,
        tools: [[String: Any]]
    ) async {
        var workingMessages = initialMessages
        var finalContent = ""

        // User-configurable cap on tool-calling rounds per message.
        // 0 (or a missing value) means unlimited.
        let configuredMaxToolCalls = (UserDefaults.standard.object(forKey: MCPServerStore.maxToolCallsKey) as? Int)
            ?? MCPServerStore.defaultMaxToolCalls
        let isUnlimited = configuredMaxToolCalls <= 0
        let maxIterations = isUnlimited ? Int.max : configuredMaxToolCalls
        var iteration = 0

        while iteration < maxIterations {
            if Task.isCancelled {
                handleComplete()
                return
            }

            iteration += 1
            let completion: ChatCompletionMessage
            do {
                completion = try await service.chatCompletion(
                    messages: workingMessages,
                    model: model,
                    temperature: temperature,
                    tools: tools
                )
            } catch {
                if Task.isCancelled {
                    handleComplete()
                } else {
                    handleError(error.localizedDescription)
                }
                return
            }

            workingMessages.append(ChatMessage(
                role: .assistant,
                content: completion.content ?? "",
                images: nil,
                toolCallId: nil,
                toolCalls: completion.toolCalls.isEmpty ? nil : completion.toolCalls
            ))

            if completion.toolCalls.isEmpty {
                finalContent = completion.content ?? ""
                break
            }

            if !completion.toolCalls.isEmpty {
                withAnimation {
                    conversationState = .loading(message: "Running \(completion.toolCalls.count) tool(s)...")
                }

                let mcpStore = MCPServerStore.shared
                var toolResults: [(String, String)] = []
                await withTaskGroup(of: (String, String).self) { group in
                    for toolCall in completion.toolCalls {
                        if Task.isCancelled { break }
                        group.addTask {
                            let result = await mcpStore.executeTool(
                                name: toolCall.function.name,
                                argumentsJSON: toolCall.function.arguments
                            )
                            return (toolCall.id, result.content)
                        }
                    }
                    for await (id, content) in group {
                        toolResults.append((id, content))
                    }
                }

                for (id, content) in toolResults {
                    workingMessages.append(ChatMessage(
                        role: .tool,
                        content: content,
                        images: nil,
                        toolCallId: id,
                        toolCalls: nil
                    ))
                }
            }
        }

        if !isUnlimited && iteration >= maxIterations && finalContent.isEmpty {
            finalContent = "Reached the maximum number of tool calls (\(maxIterations))."
        }

        guard let lastMessage = messages.last else { return }
        lastMessage.content = finalContent
        lastMessage.error = false
        lastMessage.done = true

        if !Task.isCancelled {
            Task(priority: .background) {
                try? await self.swiftDataService.updateMessage(lastMessage)
            }
        }

        withAnimation {
            conversationState = .completed
        }
        agenticTask = nil
    }
}
