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

    @State private var addingServer = false
    @State private var editingServer: MCPServerConfig?
    @State private var showingError = false

    var body: some View {
        NavigationStack {
            List {
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

                Section {
                    if store.servers.isEmpty {
                        Text(NSLocalizedString("No MCP servers configured. Add one to enable tool calling.", comment: "Empty MCP servers message"))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    }

                    ForEach(store.servers) { server in
                        serverRow(server)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingServer = server
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.remove(server)
                                } label: {
                                    Label(NSLocalizedString("Delete", comment: "Delete button"), systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(NSLocalizedString("Servers", comment: "MCP servers section header"))
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

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                Text(server.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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