//
//  MCPClient.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/09/2026.
//

import Foundation

enum MCPConnectionError: LocalizedError {
    case httpStatus(Int, String)
    case jsonRPC(Int, String)
    case invalidResponse
    case sessionExpired

    var isSessionExpired: Bool {
        switch self {
        case .httpStatus(404, _), .jsonRPC(-32002, _), .sessionExpired:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let message):
            return message.isEmpty ? "MCP server responded with HTTP \(code)" : message
        case .jsonRPC(_, let message):
            return message.isEmpty ? "MCP request failed" : message
        case .invalidResponse:
            return "Invalid response from MCP server"
        case .sessionExpired:
            return "MCP session expired"
        }
    }
}

struct MCPInitializeInfo {
    let name: String
    let version: String
}

/// A JSON-RPC 2.0 client speaking MCP's Streamable HTTP transport.
/// Handles initialize, tools/list, tools/call (including SSE streaming
/// responses with progress notifications) and basic session resumption.
final class MCPClient: @unchecked Sendable {
    private let serverId: UUID
    private let serverName: String
    private let baseURL: URL
    private let authToken: String
    private let additionalHeaders: [String: String]
    private let urlSession: URLSession
    private var nextRequestId = 1
    private(set) var sessionId: String?

    init(
        serverId: UUID,
        serverName: String,
        url: URL,
        authToken: String,
        additionalHeaders: [String: String],
        sessionId: String?
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.baseURL = url
        self.authToken = authToken
        self.additionalHeaders = additionalHeaders
        self.sessionId = sessionId

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    func clearSessionId() {
        sessionId = nil
    }

    func initialize() async throws -> MCPInitializeInfo {
        let params: [String: Any] = [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Enchanted", "version": "1.0.0"]
        ]
        let data = try await send(method: "initialize", params: params)
        let json = try parseJSON(data)
        try throwIfError(json)
        guard let result = json["result"] as? [String: Any] else {
            throw MCPConnectionError.invalidResponse
        }
        let serverInfo = result["serverInfo"] as? [String: Any] ?? [:]
        return MCPInitializeInfo(
            name: serverInfo["name"] as? String ?? "MCP Server",
            version: serverInfo["version"] as? String ?? ""
        )
    }

    func listTools() async throws -> [MCPTool] {
        let data = try await send(method: "tools/list", params: [String: Any]())
        let json = try parseJSON(data)
        try throwIfError(json)
        guard let result = json["result"] as? [String: Any],
              let toolArray = result["tools"] as? [[String: Any]] else {
            throw MCPConnectionError.invalidResponse
        }
        return toolArray.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return MCPTool(
                serverId: serverId,
                serverName: serverName,
                name: name,
                description: tool["description"] as? String ?? "",
                inputSchema: tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
            )
        }
    }

    func callTool(
        name: String,
        arguments: [String: Any],
        onProgress: @escaping (MCPProgress) -> Void
    ) async throws -> MCPToolResult {
        let requestId = nextRequestId
        nextRequestId += 1
        let params: [String: Any] = ["name": name, "arguments": arguments]
        let body: [String: Any] = ["jsonrpc": "2.0", "id": requestId, "method": "tools/call", "params": params]
        let request = try makeRequest(body: body)

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPConnectionError.invalidResponse
        }
        updateSessionId(from: http)

        if http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let message = String(data: errorData, encoding: .utf8) ?? ""
            if http.statusCode == 404 {
                throw MCPConnectionError.sessionExpired
            }
            throw MCPConnectionError.httpStatus(http.statusCode, message.isEmpty ? "HTTP \(http.statusCode)" : message)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        if !contentType.contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let json = try parseJSON(data)
            try throwIfError(json)
            guard let result = json["result"] as? [String: Any] else {
                throw MCPConnectionError.invalidResponse
            }
            return MCPToolResult(content: Self.flattenResult(result))
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }

            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }

            guard let payloadData = payload.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
                continue
            }

            if let method = json["method"] as? String, method == "notifications/progress" {
                let p = json["params"] as? [String: Any]
                let progress = p?["progress"] as? Double
                let total = p?["total"] as? Double
                var fraction: Double?
                if let progress = progress, let total = total, total > 0 {
                    fraction = progress / total
                }
                onProgress(MCPProgress(message: p?["message"] as? String, fraction: fraction))
                continue
            }

            if let id = json["id"] as? Int, id == requestId {
                if let error = json["error"] as? [String: Any] {
                    throw MCPConnectionError.jsonRPC(
                        error["code"] as? Int ?? 0,
                        error["message"] as? String ?? "Tool call failed"
                    )
                }
                if let result = json["result"] as? [String: Any] {
                    return MCPToolResult(content: Self.flattenResult(result))
                }
            }
        }
        throw MCPConnectionError.invalidResponse
    }

    // MARK: - Transport

    private func send(method: String, params: Any?) async throws -> Data {
        let requestId = nextRequestId
        nextRequestId += 1
        var body: [String: Any] = ["jsonrpc": "2.0", "id": requestId, "method": method]
        if let params = params { body["params"] = params }

        let request = try makeRequest(body: body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPConnectionError.invalidResponse
        }
        updateSessionId(from: http)

        if http.statusCode >= 400 {
            let message = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 404 {
                throw MCPConnectionError.sessionExpired
            }
            throw MCPConnectionError.httpStatus(http.statusCode, message.isEmpty ? "HTTP \(http.statusCode)" : message)
        }
        return data
    }

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId = sessionId, !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func updateSessionId(from http: HTTPURLResponse) {
        if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !newSession.isEmpty {
            sessionId = newSession
        }
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError.invalidResponse
        }
        return json
    }

    private func throwIfError(_ json: [String: Any]) throws {
        if let error = json["error"] as? [String: Any] {
            throw MCPConnectionError.jsonRPC(error["code"] as? Int ?? 0, error["message"] as? String ?? "MCP request failed")
        }
    }

    // MARK: - Result formatting

    private static func flattenResult(_ result: [String: Any]) -> String {
        let content = result["content"] as? [[String: Any]] ?? []
        let text = flattenContent(content)
        if (result["isError"] as? Bool) == true {
            return text.isEmpty ? "Tool reported an error" : text
        }
        return text
    }

    private static func flattenContent(_ content: [[String: Any]]) -> String {
        var parts: [String] = []
        for item in content {
            let type = item["type"] as? String ?? "text"
            switch type {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "image":
                parts.append("[image result]")
            case "resource":
                if let resource = item["resource"] as? [String: Any], let text = resource["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append("[resource result]")
                }
            default:
                if let text = item["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append("[\(type) result]")
                }
            }
        }
        return parts.joined(separator: "\n")
    }
}