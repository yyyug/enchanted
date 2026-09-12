//
//  MCPModels.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/09/2026.
//

import Foundation
import Combine

struct MCPServerConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var authToken: String?
    var headers: [String: String]
    var isEnabled: Bool
    var sessionId: String?
    var serverInfo: String?

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        authToken: String? = nil,
        headers: [String: String] = [:],
        isEnabled: Bool = true,
        sessionId: String? = nil,
        serverInfo: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.authToken = authToken
        self.headers = headers
        self.isEnabled = isEnabled
        self.sessionId = sessionId
        self.serverInfo = serverInfo
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, authToken, headers, isEnabled, sessionId, serverInfo
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
    }
}

struct MCPTool: Identifiable, Equatable {
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

struct MCPToolResult {
    var content: String
}

struct MCPProgress {
    let message: String?
    let fraction: Double?
}

/// Owns the list of configured MCP servers, their persistent config, live connections
/// and the merged tool catalog exposed to the agentic loop.
@MainActor
final class MCPServerStore: ObservableObject {
    static let shared = MCPServerStore()

    @Published private(set) var servers: [MCPServerConfig] = []
    @Published private(set) var tools: [MCPTool] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: String?
    @Published private(set) var progress: MCPProgress?

    private let storageKey = "mcpServers"
    private var clients: [UUID: MCPClient] = [:]
    private var connectedServerIds: Set<UUID> = []
    private var toolCache: [UUID: [MCPTool]] = [:]

    init() {
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

    func clearLastError() {
        lastError = nil
    }

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
        clients[server.id] = nil
        connectedServerIds.remove(server.id)
        toolCache.removeValue(forKey: server.id)
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

        let client = MCPClient(
            serverId: server.id,
            serverName: server.name,
            url: url,
            authToken: server.authToken ?? "",
            additionalHeaders: server.headers,
            sessionId: server.sessionId
        )
        clients[server.id] = client

        do {
            let info = try await client.initialize()
            let tools = try await client.listTools()
            toolCache[server.id] = tools
            connectedServerIds.insert(server.id)
            updateSession(for: server, sessionId: client.sessionId, serverInfo: "\(info.name) \(info.version)")
        } catch let error as MCPConnectionError where error.isSessionExpired {
            client.clearSessionId()
            do {
                let info = try await client.initialize()
                let tools = try await client.listTools()
                toolCache[server.id] = tools
                connectedServerIds.insert(server.id)
                updateSession(for: server, sessionId: client.sessionId, serverInfo: "\(info.name) \(info.version)")
            } catch {
                clients[server.id] = nil
                connectedServerIds.remove(server.id)
                lastError = "\(server.name): \(error.localizedDescription)"
            }
        } catch {
            clients[server.id] = nil
            connectedServerIds.remove(server.id)
            lastError = "\(server.name): \(error.localizedDescription)"
        }
    }

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

        do {
            return try await client.callTool(name: tool.name, arguments: arguments) { [weak self] progress in
                Task { @MainActor in
                    self?.progress = progress
                }
            }
        } catch {
            return MCPToolResult(content: "Tool '\(tool.name)' failed: \(error.localizedDescription)")
        }
    }

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
        clients[server.id] = nil
        connectedServerIds.remove(server.id)
        toolCache.removeValue(forKey: server.id)
        servers.removeAll { $0.id == server.id }
        save()
        rebuildTools()
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