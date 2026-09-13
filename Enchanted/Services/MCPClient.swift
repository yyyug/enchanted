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
    case unauthorized(wwwAuthHeader: String?)
    case timeout(seconds: TimeInterval)
    case oauth(String)
    case unsupportedProtocolVersion(String)

    var isSessionExpired: Bool {
        switch self {
        case .httpStatus(404, _), .jsonRPC(-32002, _), .sessionExpired:
            return true
        default:
            return false
        }
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
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
        case .unauthorized:
            return "MCP server requires authorization"
        case .timeout(let seconds):
            return "MCP request timed out after \(Int(seconds)) seconds"
        case .oauth(let message):
            return message
        case .unsupportedProtocolVersion(let version):
            return "Unsupported MCP protocol version: \(version)"
        }
    }
}

struct MCPInitializeInfo {
    let name: String
    let version: String
}

/// A JSON-RPC request received *from* the server (sampling / elicitation / custom).
struct MCPInboundRequest: Sendable {
    let id: Int
    let method: String
    let params: Data
}

/// The payload a client produces in response to a server-initiated request.
struct MCPInboundResult: Sendable {
    let result: Data?
    let errorCode: Int?
    let errorMessage: String?

    init(result: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        self.result = data
        self.errorCode = nil
        self.errorMessage = nil
    }

    init(errorCode: Int, errorMessage: String) {
        self.result = nil
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

/// A JSON-RPC 2.0 client speaking MCP's Streamable HTTP transport.
///
/// Handles initialize (with capability negotiation and `notifications/initialized`),
/// tools/list, tools/call (including SSE streaming responses with progress
/// notifications), a long-lived GET SSE stream for server-initiated requests,
/// session resumption, OAuth-driven 401 recovery and per-request timeouts.
final class MCPClient: @unchecked Sendable {
    static let protocolVersion = "2025-06-18"
    private static let supportedProtocolVersions: Set<String> = [
        "2024-10-07", "2024-11-05", "2025-03-26", "2025-06-18"
    ]

    /// Dispatches servers that send JSON-RPC requests (sampling, elicitation, etc).
    var onInboundRequest: (@Sendable (MCPInboundRequest) async throws -> MCPInboundResult?)?
    /// Invoked when any HTTP request returns 401; should resolve a new token and update this client.
    var on401Unauthorized: (@Sendable () async throws -> Void)?
    /// Invoked when the session is terminated (HTTP 404 / JSON-RPC -32002).
    var onSessionExpired: (@Sendable () async -> Void)?

    private let lock = NSLock()
    private let serverId: UUID
    private let serverName: String
    private let baseURL: URL
    private let additionalHeaders: [String: String]
    private let urlSession: URLSession

    private var nextRequestId = 1
    private var sessionIdInternal: String?
    private var authTokenInternal: String
    private var lastEventID = ""
    private var activeRequestIds: Set<Int> = []
    private var progressHandlers: [String: @Sendable (MCPProgress) -> Void] = [:]

    private let requestTimeoutSeconds: TimeInterval = 180

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
        self.authTokenInternal = authToken
        self.additionalHeaders = additionalHeaders
        self.sessionIdInternal = sessionId

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - State accessors

    var sessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return sessionIdInternal
    }

    func clearSessionId() {
        lock.lock(); defer { lock.unlock() }
        sessionIdInternal = nil
    }

    func updateAuthToken(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        authTokenInternal = token
    }

    private var authToken: String {
        lock.lock(); defer { lock.unlock() }
        return authTokenInternal
    }

    private func nextRequestIdValue() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { nextRequestId += 1 }
        return nextRequestId
    }

    private func registerActive(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        activeRequestIds.insert(id)
    }

    private func unregisterActive(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        activeRequestIds.remove(id)
    }

    private func activeRequestIdsSnapshot() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return Array(activeRequestIds)
    }

    private func registerProgressHandler(_ token: String, _ handler: @escaping @Sendable (MCPProgress) -> Void) {
        lock.lock(); defer { lock.unlock() }
        progressHandlers[token] = handler
    }

    private func unregisterProgressHandler(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        progressHandlers.removeValue(forKey: token)
    }

    private func progressHandler(for token: String) -> (@Sendable (MCPProgress) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return progressHandlers[token]
    }

    private func setLastEventID(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        lastEventID = id
    }

    private func getLastEventID() -> String {
        lock.lock(); defer { lock.unlock() }
        return lastEventID
    }

    private func updateSessionId(from http: HTTPURLResponse) {
        if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !newSession.isEmpty {
            lock.lock(); defer { lock.unlock() }
            sessionIdInternal = newSession
        }
    }

    private func sessionIdValue() -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionIdInternal
    }

    // MARK: - Lifecycle

    func initialize() async throws -> MCPInitializeInfo {
        let params: [String: Any] = [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [
                "sampling": [String: Any](),
                "elicitation": [String: Any]()
            ],
            "clientInfo": ["name": "Enchanted", "version": "1.0.0"]
        ]

        let data = try await performAuthorized {
            try await self.send(method: "initialize", params: params)
        }

        let json = try parseJSON(data)
        try throwIfError(json)
        guard let result = json["result"] as? [String: Any] else {
            throw MCPConnectionError.invalidResponse
        }

        if let version = result["protocolVersion"] as? String,
           !Self.supportedProtocolVersions.contains(version) {
            throw MCPConnectionError.unsupportedProtocolVersion(version)
        }

        await sendNotification(method: "notifications/initialized")

        let serverInfo = result["serverInfo"] as? [String: Any] ?? [:]
        return MCPInitializeInfo(
            name: serverInfo["name"] as? String ?? "MCP Server",
            version: serverInfo["version"] as? String ?? ""
        )
    }

    func listTools() async throws -> [MCPTool] {
        let data = try await performAuthorized {
            try await self.send(method: "tools/list", params: [String: Any]())
        }
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

    // MARK: - Tool calls

    func callTool(
        name: String,
        arguments: [String: Any],
        onProgress: @escaping @Sendable (MCPProgress) -> Void
    ) async throws -> MCPToolResult {
        let argumentsPayload = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        return try await withRequestTimeout {
            try await self._callToolInner(name: name, arguments: argumentsPayload, onProgress: onProgress)
        }
    }

    private func _callToolInner(
        name: String,
        arguments: Data,
        onProgress: @escaping @Sendable (MCPProgress) -> Void
    ) async throws -> MCPToolResult {
        let requestId = nextRequestIdValue()
        registerActive(requestId)
        defer { unregisterActive(requestId) }

        let progressToken = "tool-\(requestId)"
        registerProgressHandler(progressToken, onProgress)
        defer { unregisterProgressHandler(progressToken) }

        let argumentsObject = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let params: [String: Any] = [
            "name": name,
            "arguments": argumentsObject,
            "_meta": ["progressToken": progressToken]
        ]
        let body: [String: Any] = ["jsonrpc": "2.0", "id": requestId, "method": "tools/call", "params": params]

        return try await performAuthorized {
            let request = try self.makeRequest(body: body)
            let (bytes, response) = try await self.urlSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MCPConnectionError.invalidResponse
            }
            self.updateSessionId(from: http)

            if http.statusCode >= 400 {
                if http.statusCode == 401 {
                    throw MCPConnectionError.unauthorized(wwwAuthHeader: http.value(forHTTPHeaderField: "WWW-Authenticate"))
                }
                if http.statusCode == 404 {
                    throw MCPConnectionError.sessionExpired
                }
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte) }
                let message = String(data: errorData, encoding: .utf8) ?? ""
                throw MCPConnectionError.httpStatus(http.statusCode, message.isEmpty ? "HTTP \(http.statusCode)" : message)
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

            if !contentType.contains("text/event-stream") {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                let json = try self.parseJSON(data)
                try self.throwIfError(json)
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

                if let method = json["method"] as? String {
                    if method.hasPrefix("notifications/") {
                        if method == "notifications/progress" {
                            self.routeProgress(json["params"] as? [String: Any] ?? [:])
                        }
                        continue
                    }
                    if let handler = self.onInboundRequest,
                       let requestID = (json["id"] as? NSNumber)?.intValue {
                        let inbound = MCPInboundRequest(
                            id: requestID,
                            method: method,
                            params: Self.serializeParams(json["params"])
                        )
                        await self.respondToInbound(inbound, using: handler)
                        continue
                    }
                }

                if let id = (json["id"] as? NSNumber)?.intValue, id == requestId {
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
    }

    // MARK: - Server-initiated stream

    /// Opens the long-lived GET SSE stream used for server-to-client requests and notifications.
    func startServerStream() async {
        while !Task.isCancelled {
            var request = URLRequest(url: baseURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 300
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionId = sessionIdValue(), !sessionId.isEmpty {
                request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
            }
            let lastID = getLastEventID()
            if !lastID.isEmpty {
                request.setValue(lastID, forHTTPHeaderField: "Last-Event-ID")
            }
            let auth = authToken
            if !auth.isEmpty {
                request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
            }
            for (key, value) in additionalHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }

            do {
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                updateSessionId(from: http)

                if http.statusCode == 401 {
                    if let on401Unauthorized {
                        try await on401Unauthorized()
                        continue
                    }
                    return
                }
                if http.statusCode == 405 {
                    // Server does not offer a GET stream; server-initiated requests
                    // will arrive on POST response streams instead.
                    return
                }
                if http.statusCode == 404 {
                    await onSessionExpired?()
                    return
                }
                guard http.statusCode < 400 else { return }
                if !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
                    return
                }

                var eventBuffer = ""
                var eventID: String?
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.isEmpty {
                        if !eventBuffer.isEmpty {
                            processServerEvent(eventBuffer)
                            if let id = eventID {
                                setLastEventID(id)
                            }
                        }
                        eventBuffer = ""
                        eventID = nil
                        continue
                    }
                    if line.hasPrefix(":") { continue }
                    if line.hasPrefix("id:") {
                        let id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        if !id.isEmpty { eventID = id }
                        continue
                    }
                    if line.hasPrefix("data:") {
                        eventBuffer += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) + "\n"
                    }
                }
                // Server closed the stream. Loop to reconnect (resuming via Last-Event-ID).
            } catch {
                return
            }
        }
    }

    private func processServerEvent(_ event: String) {
        let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if let method = json["method"] as? String {
            if method.hasPrefix("notifications/") {
                if method == "notifications/progress" {
                    routeProgress(json["params"] as? [String: Any] ?? [:])
                }
                return
            }

            if let handler = onInboundRequest,
               let requestID = (json["id"] as? NSNumber)?.intValue {
                let inbound = MCPInboundRequest(
                    id: requestID,
                    method: method,
                    params: Self.serializeParams(json["params"])
                )
                Task { [weak self] in
                    guard let self else { return }
                    await self.respondToInbound(inbound, using: handler)
                }
                return
            }
        }
    }

    private func respondToInbound(
        _ inbound: MCPInboundRequest,
        using handler: @Sendable (MCPInboundRequest) async throws -> MCPInboundResult?
    ) async {
        guard let result = try? await handler(inbound) else { return }
        await postInboundResponse(id: inbound.id, result: result)
    }

    private func postInboundResponse(id: Int, result: MCPInboundResult) async {
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let resultData = result.result,
           let root = try? JSONSerialization.jsonObject(with: resultData) {
            body["result"] = root
        } else if let code = result.errorCode {
            body["error"] = ["code": code, "message": result.errorMessage ?? "Request failed"]
        } else {
            return
        }
        guard let request = try? makeRequest(body: body) else { return }
        _ = try? await urlSession.data(for: request)
    }

    private func routeProgress(_ params: [String: Any]) {
        guard let token = progressTokenString(from: params["progressToken"]) else { return }
        let value = params["progress"] as? Double
        let total = params["total"] as? Double
        var fraction: Double?
        if let value, let total, total > 0 {
            fraction = value / total
        }
        let progress = MCPProgress(message: params["message"] as? String, fraction: fraction)
        progressHandler(for: token)?(progress)
    }

    private func progressTokenString(from value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: - Transport helpers

    private func send(method: String, params: Any?) async throws -> Data {
        let requestId = nextRequestIdValue()
        registerActive(requestId)
        defer { unregisterActive(requestId) }

        var body: [String: Any] = ["jsonrpc": "2.0", "id": requestId, "method": method]
        if let params { body["params"] = params }

        return try await performAuthorized {
            let request = try self.makeRequest(body: body)
            let (data, response) = try await self.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MCPConnectionError.invalidResponse
            }
            self.updateSessionId(from: http)

            guard http.statusCode < 400 else {
                if http.statusCode == 401 {
                    throw MCPConnectionError.unauthorized(wwwAuthHeader: http.value(forHTTPHeaderField: "WWW-Authenticate"))
                }
                if http.statusCode == 404 {
                    throw MCPConnectionError.sessionExpired
                }
                let message = String(data: data, encoding: .utf8) ?? ""
                throw MCPConnectionError.httpStatus(http.statusCode, message.isEmpty ? "HTTP \(http.statusCode)" : message)
            }
            return data
        }
    }

    func sendNotification(method: String, params: [String: Any] = [:]) async {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { body["params"] = params }
        guard let request = try? makeRequest(body: body) else { return }
        _ = try? await urlSession.data(for: request)
    }

    /// POSTs `notifications/cancelled` for every currently in-flight request.
    func cancelActiveRequests(reason: String = "Request cancelled by user") async {
        for id in activeRequestIdsSnapshot() {
            await sendNotification(method: "notifications/cancelled", params: [
                "requestId": id,
                "reason": reason
            ])
        }
    }

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionId = sessionIdValue(), !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        let auth = authToken
        if !auth.isEmpty {
            request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func performAuthorized<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as MCPConnectionError where error.isUnauthorized {
            if let on401Unauthorized {
                try await on401Unauthorized()
                return try await operation()
            }
            throw error
        }
    }

    private func withRequestTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await body()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(self.requestTimeoutSeconds))
                    throw MCPConnectionError.timeout(seconds: self.requestTimeoutSeconds)
                }
                guard let first = try await group.next() else {
                    throw MCPConnectionError.timeout(seconds: self.requestTimeoutSeconds)
                }
                group.cancelAll()
                return first
            }
        } catch let error as MCPConnectionError where error.isTimeout {
            await cancelActiveRequests(reason: "Request timed out")
            throw error
        } catch {
            if Task.isCancelled {
                await cancelActiveRequests()
            }
            throw error
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

    private static func serializeParams(_ params: Any?) -> Data {
        guard let params else { return Data("{}".utf8) }
        return (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
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