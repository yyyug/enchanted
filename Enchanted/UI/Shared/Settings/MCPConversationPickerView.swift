//
//  MCPConversationPickerView.swift
//  Enchanted
//
//  Lets the user choose which MCP servers a specific conversation uses, and
//  optionally remember that choice as the default for new conversations.
//

import SwiftUI

/// Reusable multi-select list of configured MCP servers.
struct MCPServerChecklist: View {
    @ObservedObject private var store = MCPServerStore.shared
    @Binding var selection: Set<UUID>

    var body: some View {
        if store.servers.isEmpty {
            Text(NSLocalizedString("No MCP servers configured.", comment: "Debug empty state"))
                .foregroundColor(.secondary)
        } else {
            ForEach(store.servers) { server in
                Button {
                    toggle(server.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .foregroundColor(server.isEnabled ? .primary : .secondary)
                            Text(server.url)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            if !server.isEnabled {
                                Text(NSLocalizedString("Disabled", comment: "Server disabled status"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selection.contains(server.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selection.contains(server.id) ? .accentColor : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!server.isEnabled)
                .accessibilityLabel(server.name)
                .accessibilityAddTraits(selection.contains(server.id) ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

/// Sheet for editing the MCP servers used by one conversation.
struct MCPConversationPickerView: View {
    let conversation: ConversationSD
    var onSaved: () -> Void = {}

    @ObservedObject private var store = MCPServerStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var conversationStore = ConversationStore.shared

    @State private var selection: Set<UUID> = []
    @State private var makeDefault = false
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MCPServerChecklist(selection: $selection)
                } header: {
                    Text(NSLocalizedString("Servers for this conversation", comment: "Conversation MCP section"))
                } footer: {
                    Text(NSLocalizedString("Only the selected servers' tools are offered to the model in this conversation.", comment: "Conversation MCP footer"))
                }

                Section {
                    Toggle(NSLocalizedString("Use as default for new conversations", comment: "Save selection as default toggle"), isOn: $makeDefault)
                } footer: {
                    Text(NSLocalizedString("New conversations start with the default set until you change them individually.", comment: "Default set footer"))
                }
            }
            .navigationTitle(NSLocalizedString("Tools", comment: "Conversation tools title"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Save", comment: "Save button")) { save() }
                }
            }
            .task { await load() }
            .disabled(isLoading)
        }
    }

    private func load() async {
        if conversation.mcpSelectionInitialized {
            selection = Set(conversation.mcpServers.map(\.serverID))
        } else {
            selection = Set(store.defaultSelectionForNewConversation())
        }
        makeDefault = store.defaultServerIDsConfigured
            && Set(store.defaultServerIDs) == selection
        isLoading = false
    }

    private func save() {
        let ids = store.servers.map(\.id).filter { selection.contains($0) }
        Task {
            await conversationStore.setSelectedServers(ids, for: conversation, makeDefault: makeDefault)
            onSaved()
            dismiss()
        }
    }
}

/// Settings screen for the new-conversation default set. Pushed from the MCP
/// settings screen, so it deliberately does not create its own NavigationStack.
struct MCPDefaultServersView: View {
    @ObservedObject private var store = MCPServerStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var useCustomDefault = false
    @State private var selection: Set<UUID> = []

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("Custom default", comment: "Custom default toggle"), isOn: $useCustomDefault)
            } footer: {
                Text(useCustomDefault
                     ? NSLocalizedString("New conversations start with the servers you select below.", comment: "Custom default on footer")
                     : NSLocalizedString("New conversations start with every enabled server.", comment: "Custom default off footer"))
            }

            if useCustomDefault {
                Section {
                    MCPServerChecklist(selection: $selection)
                } header: {
                    Text(NSLocalizedString("Default servers", comment: "Default servers header"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("New Conversation Default", comment: "Default set title"))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("Done", comment: "Done button")) { save() }
            }
        }
        .onAppear {
            useCustomDefault = store.defaultServerIDsConfigured
            selection = Set(store.defaultServerIDs)
        }
    }

    private func save() {
        if useCustomDefault {
            store.defaultServerIDs = store.servers.map(\.id).filter { selection.contains($0) }
            store.defaultServerIDsConfigured = true
        } else {
            store.defaultServerIDs = []
            store.defaultServerIDsConfigured = false
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        MCPDefaultServersView()
    }
}
