//
//  MCPDebugView.swift
//  Enchanted
//
//  Diagnostics for configured MCP servers: connection state, session,
//  and the exact tool schemas advertised to the model.
//

import SwiftUI

struct MCPDebugView: View {
    @ObservedObject private var store = MCPServerStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.servers.isEmpty {
                    Text(NSLocalizedString("No MCP servers configured.", comment: "Debug empty state"))
                        .foregroundColor(.secondary)
                }

                ForEach(store.servers) { server in
                    Section {
                        debugRow(NSLocalizedString("Enabled", comment: "Debug enabled label"),
                                 value: server.isEnabled
                                    ? NSLocalizedString("Yes", comment: "Yes")
                                    : NSLocalizedString("No", comment: "No"))
                        debugRow(NSLocalizedString("Connected", comment: "Debug connected label"),
                                 value: store.isConnected(server)
                                    ? NSLocalizedString("Yes", comment: "Yes")
                                    : NSLocalizedString("No", comment: "No"))
                        debugRow(NSLocalizedString("Server", comment: "Debug server info label"),
                                 value: server.serverInfo ?? "—")
                        debugRow(NSLocalizedString("Session", comment: "Debug session label"),
                                 value: server.sessionId?.isEmpty == false ? server.sessionId! : "—")
                        debugRow(NSLocalizedString("Tools", comment: "Debug tool count label"),
                                 value: String(store.toolCount(for: server)))

                        Button {
                            Task { await store.reconnect(server) }
                        } label: {
                            Label(NSLocalizedString("Reconnect", comment: "Reconnect button"), systemImage: "arrow.clockwise")
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.url)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    let serverTools = store.tools.filter { $0.serverId == server.id }
                    if serverTools.isEmpty {
                        Section {
                            Text(NSLocalizedString("No tools discovered.", comment: "Debug no tools"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } header: {
                            Text(NSLocalizedString("Tool Schemas", comment: "Debug tool schemas header"))
                        }
                    } else {
                        ForEach(serverTools) { tool in
                            Section {
                                Text(tool.description.isEmpty
                                     ? NSLocalizedString("No description", comment: "Debug no description")
                                     : tool.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(schemaText(tool.inputSchema))
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            } header: {
                                Text(tool.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("MCP Debug", comment: "Debug screen title"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Done", comment: "Done button")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 500)
    }

    private func debugRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func schemaText(_ schema: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

#Preview {
    MCPDebugView()
}
