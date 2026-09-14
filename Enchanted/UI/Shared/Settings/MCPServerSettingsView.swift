//
//  MCPServerSettingsView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/09/2026.
//

import SwiftUI

struct MCPServerSettingsView: View {
    @ObservedObject private var store = MCPServerStore.shared
    @Environment(\.dismiss) private var dismiss

    @AppStorage(MCPServerStore.maxToolCallsKey) private var maxToolCalls: Int = MCPServerStore.defaultMaxToolCalls

    @State private var addingServer = false
    @State private var editingServer: MCPServerConfig?
    @State private var showingError = false

    /// Preset choices mirroring common agentic clients. 0 = unlimited.
    private let maxToolCallOptions: [Int] = [5, 10, 20, 50, 100, 0]

    var body: some View {
        NavigationStack {
            List {
                // Servers first: existing servers, then an explicit add button.
                Section {
                    if store.servers.isEmpty {
                        Text(NSLocalizedString("No MCP servers configured. Add one to enable tool calling.", comment: "Empty MCP servers message"))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    }

                    ForEach(store.servers) { server in
                        serverRow(server)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.remove(server)
                                } label: {
                                    Label(NSLocalizedString("Delete", comment: "Delete button"), systemImage: "trash")
                                }
                            }
                    }

                    Button {
                        addingServer = true
                    } label: {
                        Label(NSLocalizedString("Add MCP Server", comment: "Add MCP server row"), systemImage: "plus.circle.fill")
                    }
                    .accessibilityLabel(NSLocalizedString("Add MCP server", comment: "Add MCP server button"))
                } header: {
                    Text(NSLocalizedString("Servers", comment: "MCP servers section header"))
                }

                // Options come after the server list.
                Section {
                    Picker(NSLocalizedString("Max Tool Calls", comment: "Max tool calls label"), selection: $maxToolCalls) {
                        ForEach(maxToolCallOptions, id: \.self) { value in
                            Text(value == 0
                                 ? NSLocalizedString("Unlimited", comment: "Unlimited tool calls option")
                                 : String(value))
                                .tag(value)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Tool Execution", comment: "Tool execution section header"))
                } footer: {
                    Text(NSLocalizedString("Maximum number of tool-calling rounds the assistant may run per message. Choose Unlimited to remove the cap.", comment: "Max tool calls footer"))
                }

                Section {
                    Picker(NSLocalizedString("Sampling", comment: "Sampling policy label"), selection: $store.samplingPolicy) {
                        ForEach(MCPSamplingPolicy.allCases) { policy in
                            Text(NSLocalizedString(policy.title, comment: "Sampling policy option")).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle(NSLocalizedString("Cache tool results (60s)", comment: "Tool result cache toggle"), isOn: $store.toolResultCacheEnabled)
                } header: {
                    Text(NSLocalizedString("MCP Settings", comment: "MCP settings section header"))
                } footer: {
                    Text(NSLocalizedString("Sampling controls how servers may request LLM completions directly.", comment: "Sampling settings footer"))
                }
            }
            .navigationTitle(NSLocalizedString("MCP Servers", comment: "MCP servers title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Done", comment: "Done button")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addingServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("Add MCP server", comment: "Add MCP server button"))
                }
            }
            .sheet(isPresented: $addingServer) {
                MCPServerEditorView(server: nil)
                    .frame(maxWidth: 700)
            }
            .sheet(item: $editingServer) { server in
                MCPServerEditorView(server: server)
                    .frame(maxWidth: 700)
            }
            .onChange(of: store.lastError) { _, newValue in
                if newValue != nil {
                    showingError = true
                }
            }
            .alert(NSLocalizedString("MCP Server Error", comment: "MCP server error alert title"), isPresented: $showingError) {
                Button(NSLocalizedString("OK", comment: "OK button"), role: .cancel) { store.clearLastError() }
            } message: {
                Text(store.lastError ?? "")
            }
        }
        .frame(minWidth: 420, minHeight: 500)
    }

    private func statusColor(_ server: MCPServerConfig) -> Color {
        if !server.isEnabled { return Color.secondary.opacity(0.4) }
        return store.isConnected(server) ? Color.green : Color.orange
    }

    private func statusDescription(_ server: MCPServerConfig) -> String {
        if !server.isEnabled {
            return NSLocalizedString("Disabled", comment: "Server disabled status")
        }
        return store.isConnected(server)
            ? NSLocalizedString("Connected", comment: "Server connected status")
            : NSLocalizedString("Not connected", comment: "Server not connected status")
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: Binding(
                get: { server.isEnabled },
                set: { store.setEnabled(server, $0) }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .accessibilityLabel(String(
                format: NSLocalizedString("Enable %@", comment: "Enable server toggle"),
                server.name
            ))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(server))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(server.name)
                        .font(.body)
                }
                Text(server.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(statusDescription(server))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let info = server.serverInfo {
                    Text(info)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if store.hasOAuthToken(for: server) {
                    Label(NSLocalizedString("OAuth authorized", comment: "OAuth authorized label"), systemImage: "checkmark.shield")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                editingServer = server
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(NSLocalizedString("Double tap to edit", comment: "Edit server hint"))

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("%lld tools", comment: "Tool count"),
                    store.toolCount(for: server)
                ))
                .font(.caption)
                .foregroundColor(.secondary)

                Button {
                    if store.hasOAuthToken(for: server) {
                        store.signOut(server: server)
                    } else {
                        Task {
                            await store.signIn(server: server)
                        }
                    }
                } label: {
                    Text(store.hasOAuthToken(for: server)
                         ? NSLocalizedString("Sign Out", comment: "Sign out button")
                         : NSLocalizedString("Sign In", comment: "Sign in button"))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!server.isEnabled)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MCPServerEditorView: View {
    @ObservedObject private var store = MCPServerStore.shared
    @Environment(\.dismiss) private var dismiss

    let server: MCPServerConfig?

    @State private var name: String
    @State private var url: String
    @State private var authToken: String
    @State private var isEnabled: Bool
    @State private var isConnecting = false

    init(server: MCPServerConfig?) {
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _url = State(initialValue: server?.url ?? "")
        _authToken = State(initialValue: server?.authToken ?? "")
        _isEnabled = State(initialValue: server?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .disableAutocorrection(true)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                TextField("URL", text: $url)
                    .disableAutocorrection(true)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
#if os(iOS)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
#endif

                SecureField("Bearer Token (optional)", text: $authToken)
                    .disableAutocorrection(true)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Toggle("Enabled", isOn: $isEnabled)

                if isConnecting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting...")
                    }
                }

                if let lastError = store.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .navigationTitle(server == nil ? "Add MCP Server" : "Edit MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .frame(minWidth: 420)
    }

    private func save() {
        var trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.last == "/" {
            trimmedURL = String(trimmedURL.dropLast())
        }

        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let config: MCPServerConfig
        if let server = server {
            config = MCPServerConfig(
                id: server.id,
                name: name,
                url: trimmedURL,
                authToken: token.isEmpty ? nil : token,
                headers: server.headers,
                isEnabled: isEnabled,
                sessionId: server.sessionId,
                serverInfo: server.serverInfo
            )
        } else {
            config = MCPServerConfig(
                name: name,
                url: trimmedURL,
                authToken: token.isEmpty ? nil : token,
                isEnabled: isEnabled
            )
        }

        store.upsert(config)
        isConnecting = true
        Task {
            await store.reconnect(config)
            isConnecting = false
            dismiss()
        }
    }
}

#Preview {
    MCPServerSettingsView()
}