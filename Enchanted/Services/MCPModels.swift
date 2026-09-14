//
//  MCPModels.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/09/2026.
//

import Foundation
import Combine
import CryptoKit

struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var url: String
    var authToken: String?
    var headers: [String: String]
    var isEnabled: Bool
    var sessionId: String?
    var serverInfo: String?
    /// Optional custom system prompt appended to the global prompt while this
    /// server is enabled.
    var systemPrompt: String?
    /// Optional manual OAuth client credentials. When set, dynamic client
    /// registration is skipped.
    var oauthClientId: String?
    var oauthClientSecret: String?

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        authToken: String? = nil,
        headers: [String: String] = [:],
        isEnabled: Bool = true,
        sessionId: String? = nil,
        serverInfo: String? = nil,
        systemPrompt: String? = nil,
        oauthClientId: String? = nil,
        oauthClientSecret: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.authToken = authToken
        self.headers = headers
        self.isEnabled = isEnabled
        self.sessionId = sessionId
        self.serverInfo = serverInfo
        self.systemPrompt = systemPrompt
        self.oauthClientId = oauthClientId
        self.oauthClientSecret = oauthClientSecret
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, authToken, headers, isEnabled, sessionId, serverInfo
        case systemPrompt, oauthClientId, oauthClientSecret
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        serverInfo = try container.decodeIfPresent(String.self, forKey: .serverInfo)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        oauthClientId = try container.decodeIfPresent(String.self, forKey: .oauthClientId)
        oauthClientSecret = try container.decodeIfPresent(String.self, forKey: .oauthClientSecret)
    }

    /// Renders the custom headers as the editable multi-line `Key: Value` form.
    var headersText: String {
        headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Parses `Key: Value` lines. Values may themselves contain colons
    /// (e.g. URLs); only the first colon separates key from value.
    static func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}

/// Outcome of an ad-hoc connection test from the server editor.
enum MCPConnectionTestResult: Sendable, Equatable {
    case success(toolCount: Int, serverInfo: String)
    case failure(String)
}

struct MCPTool: Identifiable {
    let serverId: UUID
    let serverName: String
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var id: String { "\(serverId.uuidString).\(name)" }

    var openAITool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": inputSchema
            ]
        ]
    }
}

struct MCPToolResult: Sendable {
    var content: String
}

struct MCPProgress: Sendable, Equatable {
    let message: String?
    let fraction: Double?
}

// MARK: - Sampling

enum MCPSamplingPolicy: Int, Codable, CaseIterable, Identifiable {
    case askAlways = 0
    case allowAlways = 1
    case deny = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .askAlways: return "Always ask"
        case .allowAlways: return "Auto-approve"
        case .deny: return "Always deny"
        }
    }
}

struct MCPSamplingRequest {
    let serverId: UUID
    let serverName: String
    let messages: [[String: Any]]
    let systemPrompt: String?
    let maxTokens: Int?
    let temperature: Double?
    let hints: [String]

    init?(serverId: UUID, serverName: String, params: [String: Any]) {
        guard let messages = params["messages"] as? [[String: Any]] else { return nil }
        self.serverId = serverId
        self.serverName = serverName
        self.messages = messages
        self.systemPrompt = params["systemPrompt"] as? String
        self.maxTokens = (params["maxTokens"] as? NSNumber)?.intValue
        self.temperature = params["temperature"] as? Double
        if let preferences = params["modelPreferences"] as? [String: Any],
           let hints = preferences["hints"] as? [[String: Any]] {
            self.hints = hints.compactMap { $0["name"] as? String }
        } else {
            self.hints = []
        }
    }

    var promptPreview: String {
        var parts: [String] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            if let content = message["content"] as? String, !content.isEmpty {
                parts.append("[\(role)]\n\(content)\n")
            } else if let contentArray = message["content"] as? [[String: Any]] {
                let texts = contentArray.compactMap { $0["text"] as? String }
                if !texts.isEmpty {
                    parts.append("[\(role)]\n\(texts.joined(separator: "\n"))\n")
                } else if let type = contentArray.first?["type"] as? String {
                    parts.append("[\(role)]\n[\(type) message]\n")
                }
            }
        }
        return parts.joined(separator: "\n")
    }
}

enum MCPSamplingAction {
    case allow(responseText: String?)
    case cancel
}

struct MCPSamplingPresentation: Identifiable {
    let id = UUID()
    let request: MCPSamplingRequest
    var responseText: String?
    var modelName: String?
    var isGenerating = false
    var errorMessage: String?
}

// MARK: - Elicitation

struct MCPElicitationField {
    let name: String
    let title: String?
    let description: String?
    let type: String
    let format: String?
    let enumValues: [String]
    let enumNames: [String]
    let minimum: Double?
    let maximum: Double?
    let minLength: Int?
    let maxLength: Int?
    let defaultValue: Any?
}

struct MCPElicitationSchema {
    let properties: [MCPElicitationField]
    let required: Set<String>

    init?(json: Any?) {
        guard let dict = json as? [String: Any],
              let propertiesDict = dict["properties"] as? [String: Any] else { return nil }
        var fields: [MCPElicitationField] = []
        for (name, raw) in propertiesDict {
            guard let fieldDict = raw as? [String: Any] else { continue }
            let fieldType = fieldDict["type"] as? String ?? "string"
            fields.append(MCPElicitationField(
                name: name,
                title: fieldDict["title"] as? String,
                description: fieldDict["description"] as? String,
                type: fieldType,
                format: fieldDict["format"] as? String,
                enumValues: fieldDict["enum"] as? [String] ?? [],
                enumNames: fieldDict["enumNames"] as? [String] ?? [],
                minimum: fieldDict["minimum"] as? Double,
                maximum: fieldDict["maximum"] as? Double,
                minLength: fieldDict["minLength"] as? Int,
                maxLength: fieldDict["maxLength"] as? Int,
                defaultValue: fieldDict["default"]
            ))
        }
        self.properties = fields
        self.required = Set(dict["required"] as? [String] ?? [])
    }
}

struct MCPElicitationRequest {
    let serverId: UUID
    let serverName: String
    let message: String
    let schema: MCPElicitationSchema?

    init?(serverId: UUID, serverName: String, params: [String: Any]) {
        guard let message = params["message"] as? String else { return nil }
        self.serverId = serverId
        self.serverName = serverName
        self.message = message
        self.schema = MCPElicitationSchema(json: params["requestedSchema"])
    }
}

enum MCPElicitationAction {
    case submit([String: Any])
    case decline
    case cancel
}

struct MCPElicitationPresentation: Identifiable {
    let id = UUID()
    let request: MCPElicitationRequest
}

// MARK: - OAuth

struct MCPAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(30) > expiresAt
    }
}

struct MCPOAuthSession: Codable {
    var clientID: String
    var clientSecret: String?
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var registrationEndpoint: String?
    var revocationEndpoint: String?
    var asMetadataURL: String
    var resourceURI: String
}

// MARK: - Store

/// Owns the list of configured MCP servers, their persistent config, live connections,
/// the merged tool catalog, and the inbound sampling / elicitation request pipeline.
@MainActor
final class MCPServerStore: ObservableObject {
    static let shared = MCPServerStore()

    @Published private(set) var servers: [MCPServerConfig] = []
    @Published private(set) var tools: [MCPTool] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: String?
    @Published private(set) var progress: MCPProgress?

    @Published var pendingSampling: MCPSamplingPresentation?
    @Published var pendingElicitation: MCPElicitationPresentation?

    @Published var samplingPolicy: MCPSamplingPolicy {
        didSet { UserDefaults.standard.set(samplingPolicy.rawValue, forKey: "mcpSamplingPolicy") }
    }
    @Published var toolResultCacheEnabled: Bool {
        didSet { UserDefaults.standard.set(toolResultCacheEnabled, forKey: "mcpToolResultCacheEnabled") }
    }

    /// The LLM model used to fulfill server sampling requests.
    var samplingModelName: String?

    /// Default number of agentic tool-calling iterations per message.
    static let defaultMaxToolCalls = 12
    /// `UserDefaults` key for the max tool calls setting. 0 means unlimited.
    static let maxToolCallsKey = "maxToolCalls"
    /// `UserDefaults` keys for the "servers used by new conversations" default.
    static let defaultServerIDsKey = "mcpDefaultServerIds"
    static let defaultServerIDsConfiguredKey = "mcpDefaultServersConfigured"

    private let storageKey = "mcpServers"
    private var clients: [UUID: MCPClient] = [:]
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var connectedServerIds: Set<UUID> = []
    private var toolCache: [UUID: [MCPTool]] = [:]
    private var toolResultCache: [String: (MCPToolResult, Date)] = [:]

    private var samplingContinuation: CheckedContinuation<MCPSamplingAction, Never>?
    private var elicitationContinuation: CheckedContinuation<MCPElicitationAction, Never>?

    private let toolCacheTTL: TimeInterval = 60

    init() {
        samplingPolicy = MCPSamplingPolicy(rawValue: UserDefaults.standard.integer(forKey: "mcpSamplingPolicy")) ?? .askAlways
        toolResultCacheEnabled = UserDefaults.standard.bool(forKey: "mcpToolResultCacheEnabled")
        load()
    }

    var connectedServerCount: Int {
        servers.filter { connectedServerIds.contains($0.id) }.count
    }

    var hasEnabledServers: Bool {
        servers.contains { $0.isEnabled }
    }

    var availableTools: [[String: Any]] {
        tools.map { $0.openAITool }
    }

    func toolCount(for server: MCPServerConfig) -> Int {
        toolCache[server.id]?.count ?? 0
    }

    func isConnected(_ server: MCPServerConfig) -> Bool {
        connectedServerIds.contains(server.id)
    }

    // MARK: - New-conversation default set

    /// Servers a brand-new conversation starts with.
    var defaultServerIDs: [UUID] {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: Self.defaultServerIDsKey) ?? []
            return stored.compactMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.defaultServerIDsKey)
        }
    }

    /// Whether the user has ever chosen a default set. Distinguishes an
    /// explicit "none" from "never configured".
    var defaultServerIDsConfigured: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultServerIDsConfiguredKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultServerIDsConfiguredKey) }
    }

    /// Selection used for a conversation that has never been configured.
    /// Explicit default set wins; otherwise fall back to every enabled server so
    /// existing behaviour is preserved after upgrading.
    func defaultSelectionForNewConversation() -> [UUID] {
        let existing = Set(servers.map(\.id))
        if defaultServerIDsConfigured {
            return defaultServerIDs.filter { existing.contains($0) }
        }
        return servers.filter(\.isEnabled).map(\.id)
    }

    /// Custom system prompts contributed by enabled servers, appended to the
    /// global system prompt while those servers are enabled.
    var enabledSystemPrompts: [String] {
        servers.filter { $0.isEnabled }.compactMap { server in
            let trimmed = server.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
    }

    /// Ad-hoc connection test used by the server editor so users can validate a
    /// URL, headers and token before saving.
    func testConnection(url: String, headers: [String: String], authToken: String?) async -> MCPConnectionTestResult {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: trimmed), let scheme = parsedURL.scheme, !scheme.isEmpty else {
            return .failure(NSLocalizedString("Enter a valid URL", comment: "Invalid URL for connection test"))
        }

        let client = MCPClient(
            serverId: UUID(),
            serverName: "connection-test",
            url: parsedURL,
            authToken: authToken ?? "",
            additionalHeaders: headers,
            sessionId: nil
        )

        do {
            let info = try await client.initialize()
            let tools = try await client.listTools()
            let serverInfo = [info.name, info.version]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return .success(toolCount: tools.count, serverInfo: serverInfo)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Enables or disables a server from the list. Enabling reconnects it;
    /// disabling tears down its connection and removes its tools.
    func setEnabled(_ server: MCPServerConfig, _ enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        guard servers[index].isEnabled != enabled else { return }
        servers[index].isEnabled = enabled
        let updated = servers[index]
        save()

        if enabled {
            Task { await reconnect(updated) }
        } else {
            disconnect(updated)
        }
    }

    func disconnect(_ server: MCPServerConfig) {
        stopServerStream(for: server.id)
        clients[server.id] = nil
        connectedServerIds.remove(server.id)
        toolCache.removeValue(forKey: server.id)
        rebuildTools()
    }

    func clearLastError() {
        lastError = nil
    }

    // MARK: - Connection

    func connectAll() async {
        guard hasEnabledServers, !isConnecting else { return }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }

        for server in servers where server.isEnabled {
            await connect(server)
        }
        rebuildTools()
    }

    func reconnect(_ server: MCPServerConfig) async {
        stopServerStream(for: server.id)
        clients[server.id] = nil
        connectedServerIds.remove(server.id)
        toolCache.removeValue(forKey: server.id)
        resetPendingRequests()
        // Drop cached tool results so a reconnected server never serves stale data.
        toolResultCache.removeAll()
        rebuildTools()
        await connect(server)
        rebuildTools()
    }

    func connect(_ server: MCPServerConfig) async {
        lastError = nil
        if connectedServerIds.contains(server.id) { return }

        guard let url = URL(string: server.url) else {
            lastError = "\(server.name): invalid URL"
            return
        }

        let client = makeClient(for: server, url: url)
        clients[server.id] = client

        do {
            try await connectWithRetries(server: server, client: client)
            startServerStream(server: server, client: client)
        } catch {
            clients[server.id] = nil
            connectedServerIds.remove(server.id)
            lastError = "\(server.name): \(error.localizedDescription)"
        }
    }

    private func connectWithRetries(server: MCPServerConfig, client: MCPClient) async throws {
        do {
            try await establishSession(server: server, client: client)
        } catch let error as MCPConnectionError where error.isSessionExpired {
            client.clearSessionId()
            try await establishSession(server: server, client: client)
        } catch let error as MCPConnectionError where error.isUnauthorized {
            try await ensureAuthorized(for: server)
            try await establishSession(server: server, client: client)
        }
    }

    private func establishSession(server: MCPServerConfig, client: MCPClient) async throws {
        let info = try await client.initialize()
        let tools = try await client.listTools()
        toolCache[server.id] = tools
        connectedServerIds.insert(server.id)
        updateSession(for: server, sessionId: client.sessionId, serverInfo: "\(info.name) \(info.version)")
    }

    private func reestablishSession(server: MCPServerConfig) async {
        guard connectedServerIds.contains(server.id), let client = clients[server.id] else { return }
        stopServerStream(for: server.id)
        resetPendingRequests()
        client.clearSessionId()
        do {
            try await connectWithRetries(server: server, client: client)
            startServerStream(server: server, client: client)
            rebuildTools()
        } catch {
            lastError = "\(server.name): \(error.localizedDescription)"
        }
    }

    private func makeClient(for server: MCPServerConfig, url: URL) -> MCPClient {
        let client = MCPClient(
            serverId: server.id,
            serverName: server.name,
            url: url,
            authToken: server.authToken ?? "",
            additionalHeaders: server.headers,
            sessionId: server.sessionId
        )

        client.onInboundRequest = { [weak self, server] inbound in
            guard let self else { return nil }
            return await self.handleInbound(inbound, for: server)
        }

        client.on401Unauthorized = { [weak self, server] in
            guard let self else { return }
            try await self.ensureAuthorized(for: server)
            await MainActor.run {
                if let token = MCPTokenStore.load(serverId: server.id) {
                    self.clients[server.id]?.updateAuthToken("Bearer \(token.accessToken)")
                }
            }
        }

        client.onSessionExpired = { [weak self, server] in
            guard let self else { return }
            await self.reestablishSession(server: server)
        }

        return client
    }

    private func startServerStream(server: MCPServerConfig, client: MCPClient) {
        streamTasks[server.id]?.cancel()
        let task = Task { [weak client] in
            guard let client else { return }
            await client.startServerStream()
        }
        streamTasks[server.id] = task
    }

    private func stopServerStream(for serverId: UUID) {
        streamTasks[serverId]?.cancel()
        streamTasks[serverId] = nil
    }

    // MARK: - Inbound requests

    private func handleInbound(_ inbound: MCPInboundRequest, for server: MCPServerConfig) async -> MCPInboundResult? {
        let params: [String: Any]
        do {
            params = try Self.parseJSON(inbound.params)
        } catch {
            return MCPInboundResult(errorCode: -32700, errorMessage: "Parse error")
        }

        switch inbound.method {
        case "sampling/createMessage":
            guard let request = MCPSamplingRequest(serverId: server.id, serverName: server.name, params: params) else {
                return MCPInboundResult(errorCode: -32602, errorMessage: "Invalid sampling request")
            }
            return await handleSampling(request)
        case "elicitation/create":
            guard let request = MCPElicitationRequest(serverId: server.id, serverName: server.name, params: params) else {
                return MCPInboundResult(errorCode: -32602, errorMessage: "Invalid elicitation request")
            }
            return await handleElicitation(request)
        default:
            return MCPInboundResult(errorCode: -32601, errorMessage: "Method not supported: \(inbound.method)")
        }
    }

    private func handleSampling(_ request: MCPSamplingRequest) async -> MCPInboundResult {
        let action: MCPSamplingAction
        switch samplingPolicy {
        case .askAlways:
            action = await presentSampling(request)
        case .allowAlways:
            action = .allow(responseText: nil)
        case .deny:
            action = .cancel
        }

        let responseText: String?
        switch action {
        case .cancel:
            return MCPInboundResult(errorCode: -1, errorMessage: "User rejected the sampling request")
        case .allow(let preview):
            responseText = preview
        }

        guard let model = samplingModelName else {
            return MCPInboundResult(errorCode: -32603, errorMessage: "No LLM model is configured for sampling")
        }

        do {
            let text: String
            if let responseText, !responseText.isEmpty {
                text = responseText
            } else {
                text = try await sample(request: request, model: model)
            }
            let payload: [String: Any] = [
                "role": "assistant",
                "content": ["type": "text", "text": text],
                "model": model,
                "stopReason": "endTurn"
            ]
            return MCPInboundResult(result: payload)
        } catch {
            return MCPInboundResult(errorCode: -32603, errorMessage: "Sampling failed: \(error.localizedDescription)")
        }
    }

    private func handleElicitation(_ request: MCPElicitationRequest) async -> MCPInboundResult {
        let action = await presentElicitation(request)
        switch action {
        case .submit(let content):
            return MCPInboundResult(result: ["action": "accept", "content": content])
        case .decline:
            return MCPInboundResult(result: ["action": "decline"])
        case .cancel:
            return MCPInboundResult(result: ["action": "cancel"])
        }
    }

    private func presentSampling(_ request: MCPSamplingRequest) async -> MCPSamplingAction {
        pendingSampling = MCPSamplingPresentation(request: request)
        let action: MCPSamplingAction = await withCheckedContinuation { continuation in
            samplingContinuation = continuation
        }
        pendingSampling = nil
        return action
    }

    private func presentElicitation(_ request: MCPElicitationRequest) async -> MCPElicitationAction {
        pendingElicitation = MCPElicitationPresentation(request: request)
        let action: MCPElicitationAction = await withCheckedContinuation { continuation in
            elicitationContinuation = continuation
        }
        pendingElicitation = nil
        return action
    }

    func respondToSampling(_ action: MCPSamplingAction) {
        guard let continuation = samplingContinuation else { return }
        samplingContinuation = nil
        continuation.resume(returning: action)
    }

    func respondToElicitation(_ action: MCPElicitationAction) {
        guard let continuation = elicitationContinuation else { return }
        elicitationContinuation = nil
        continuation.resume(returning: action)
    }

    private func resetPendingRequests() {
        if let continuation = samplingContinuation {
            samplingContinuation = nil
            continuation.resume(returning: .cancel)
        }
        if let continuation = elicitationContinuation {
            elicitationContinuation = nil
            continuation.resume(returning: .cancel)
        }
        pendingSampling = nil
        pendingElicitation = nil
    }

    // MARK: - Sampling generation

    func startSamplingGeneration() {
        guard var presentation = pendingSampling else { return }
        guard let model = samplingModelName else {
            presentation.errorMessage = "No LLM model is configured for sampling"
            pendingSampling = presentation
            return
        }
        presentation.isGenerating = true
        presentation.errorMessage = nil
        pendingSampling = presentation

        Task { @MainActor in
            do {
                let text = try await sample(request: presentation.request, model: model)
                var updated = self.pendingSampling ?? presentation
                updated.responseText = text
                updated.modelName = model
                updated.isGenerating = false
                self.pendingSampling = updated
            } catch {
                var updated = self.pendingSampling ?? presentation
                updated.isGenerating = false
                updated.errorMessage = error.localizedDescription
                self.pendingSampling = updated
            }
        }
    }

    private func sample(request: MCPSamplingRequest, model: String) async throws -> String {
        let messages = Self.buildSamplingMessages(request)
        let service: any ChatCompletionProviding = OpenAIService.shared
        let completion = try await service.chatCompletion(messages: messages, model: model, temperature: request.temperature, tools: nil)
        guard let content = completion.content, !content.isEmpty else {
            throw MCPConnectionError.jsonRPC(-31002, "Sampling produced no output")
        }
        return content
    }

    private static func buildSamplingMessages(_ request: MCPSamplingRequest) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            messages.append(ChatMessage(role: .system, content: systemPrompt))
        }
        for item in request.messages {
            let role = ChatMessage.Role(rawValue: item["role"] as? String ?? "user") ?? .user
            let text: String
            if let content = item["content"] as? String {
                text = content
            } else if let contentArray = item["content"] as? [[String: Any]] {
                text = contentArray.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                text = ""
            }
            guard !text.isEmpty else { continue }
            messages.append(ChatMessage(role: role, content: text))
        }
        return messages
    }

    private static func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError.invalidResponse
        }
        return json
    }

    // MARK: - Tool execution

    func executeTool(name: String, argumentsJSON: String) async -> MCPToolResult {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return MCPToolResult(content: "Tool '\(name)' not found on any connected MCP server.")
        }

        guard let client = clients[tool.serverId] else {
            return MCPToolResult(content: "MCP server '\(tool.serverName)' is not connected.")
        }

        let arguments: [String: Any]
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = object
        } else {
            arguments = [:]
        }

        if toolResultCacheEnabled {
            let key = "\(tool.name):\(Self.hashKey(Self.canonicalArgumentsJSON(arguments)))"
            if let cached = toolResultCache[key], Date().timeIntervalSince(cached.1) < toolCacheTTL {
                return cached.0
            }
        }

        progress = nil
        do {
            let result = try await client.callTool(
                name: tool.name,
                arguments: arguments
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.progress = progress
                }
            }

            if toolResultCacheEnabled {
                let key = "\(tool.name):\(Self.hashKey(Self.canonicalArgumentsJSON(arguments)))"
                toolResultCache[key] = (result, Date())
            }
            progress = nil
            return result
        } catch let error as MCPConnectionError where error.isSessionExpired {
            progress = nil
            await client.onSessionExpired?()
            return MCPToolResult(content: "Tool '\(tool.name)' failed because the MCP session expired. Please try again.")
        } catch let error as MCPConnectionError {
            progress = nil
            return MCPToolResult(content: "Tool '\(tool.name)' failed: \(error.localizedDescription)")
        } catch {
            progress = nil
            return MCPToolResult(content: "Tool '\(tool.name)' failed: \(error.localizedDescription)")
        }
    }

    /// Cancels in-flight requests on every connected server and clears progress.
    func cancelToolExecution() async {
        progress = nil
        resetPendingRequests()
        for client in clients.values {
            await client.cancelActiveRequests()
        }
    }

    private static func canonicalArgumentsJSON(_ arguments: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func hashKey(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Authorization

    func hasOAuthToken(for server: MCPServerConfig) -> Bool {
        MCPTokenStore.load(serverId: server.id) != nil
    }

    func signIn(server: MCPServerConfig) async {
        do {
            let token = try await MCPOAuthClient.shared.obtainToken(for: server)
            clients[server.id]?.updateAuthToken("Bearer \(token.accessToken)")
            if !connectedServerIds.contains(server.id) {
                await connect(server)
                rebuildTools()
            }
        } catch {
            lastError = "\(server.name): authorization failed - \(error.localizedDescription)"
        }
    }

    func signOut(server: MCPServerConfig) {
        MCPTokenStore.delete(serverId: server.id)
        clients[server.id]?.updateAuthToken("")
    }

    private func ensureAuthorized(for server: MCPServerConfig) async throws {
        let token = try await MCPOAuthClient.shared.obtainToken(for: server)
        clients[server.id]?.updateAuthToken("Bearer \(token.accessToken)")
    }

    // MARK: - CRUD

    func upsert(_ server: MCPServerConfig) {
        var copy = server
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            let existing = servers[idx]
            copy.sessionId = existing.sessionId
            copy.serverInfo = existing.serverInfo
            servers[idx] = copy
        } else {
            servers.append(copy)
        }
        save()
    }

    func remove(_ server: MCPServerConfig) {
        stopServerStream(for: server.id)
        clients[server.id] = nil
        connectedServerIds.remove(server.id)
        toolCache.removeValue(forKey: server.id)
        servers.removeAll { $0.id == server.id }
        save()
        rebuildTools()

        // Drop the server from conversation selections and the default set so no
        // dangling references survive.
        if defaultServerIDs.contains(server.id) {
            defaultServerIDs = defaultServerIDs.filter { $0 != server.id }
        }
        Task {
            try? await SwiftDataService.shared.removeServerAssociations(serverID: server.id)
        }
    }

    private func updateSession(for server: MCPServerConfig, sessionId: String?, serverInfo: String?) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        var copy = servers[idx]
        copy.sessionId = sessionId
        copy.serverInfo = serverInfo
        servers[idx] = copy
        save()
    }

    private func rebuildTools() {
        var all: [MCPTool] = []
        for server in servers where server.isEnabled {
            all.append(contentsOf: toolCache[server.id] ?? [])
        }
        tools = all
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return
        }
        servers = decoded
    }
}