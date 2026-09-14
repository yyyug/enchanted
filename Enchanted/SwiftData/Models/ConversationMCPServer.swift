//
//  ConversationMCPServer.swift
//  Enchanted
//
//  Associates an MCP server with a conversation. The session id lives here
//  (not on MCPServerConfig) so each conversation talks to a server over its
//  own isolated MCP session.
//

import Foundation
import SwiftData

@Model
final class ConversationMCPServer: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()

    /// `MCPServerConfig.id`. Configs live in UserDefaults, so this is a loose
    /// reference rather than a SwiftData relationship.
    var serverID: UUID

    /// MCP `Mcp-Session-Id` for this conversation/server pair.
    var sessionID: String?

    var addedAt: Date = Date.now

    @Relationship var conversation: ConversationSD?

    init(serverID: UUID, conversation: ConversationSD? = nil) {
        self.serverID = serverID
        self.conversation = conversation
    }
}

// MARK: - @unchecked Sendable
extension ConversationMCPServer: @unchecked Sendable {
    /// Compiler warning silencer only. Mutate exclusively through
    /// `SwiftDataService` so concurrent writes stay serialized.
}
