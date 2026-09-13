//
//  MCPSamplingView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/09/2026.
//

import SwiftUI

struct MCPSamplingView: View {
    @ObservedObject private var store = MCPServerStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if let _ = store.pendingSampling {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            content
                                .padding(20)
                        }
                        Divider()
                        footer
                            .padding(16)
                    }
                } else {
                    EmptyView()
                }
            }
            .navigationTitle(NSLocalizedString("Sampling Request", comment: "MCP sampling sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "Close button")) { store.respondToSampling(.cancel) }
                }
            }
        }
        .frame(maxWidth: 700)
        .frame(minWidth: 420, minHeight: 460)
    }

    private var content: some View {
        guard let presentation = store.pendingSampling else {
            return AnyView(EmptyView())
        }

        let request = presentation.request

        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("%@ is requesting a model completion", comment: "MCP sampling request header"),
                        request.serverName
                    ))
                    .font(.headline)
                } icon: {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.accentColor)
                }

                if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
                    promptBlock(title: NSLocalizedString("System Prompt", comment: "System prompt label"), text: systemPrompt)
                }

                promptBlock(title: NSLocalizedString("Conversation", comment: "Conversation label"), text: request.promptPreview)

                if let error = presentation.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if let responseText = presentation.responseText {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.accentColor)
                            Text(presentation.modelName.map {
                                String.localizedStringWithFormat(
                                    NSLocalizedString("Response from %@", comment: "Sampling response model label"),
                                    $0
                                )
                            } ?? NSLocalizedString("Generated response", comment: "Generated response label"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        Text(responseText)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.15))
                            )
                    }
                }
            }
        )
    }

    private func promptBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(nil)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.15))
                )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let presentation = store.pendingSampling {
                if presentation.isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(NSLocalizedString("Generating a response...", comment: "Generating sampling response"))
                            .foregroundColor(.secondary)
                    }
                } else if presentation.responseText == nil {
                    HStack {
                        Button {
                            store.startSamplingGeneration()
                        } label: {
                            Label(NSLocalizedString("Generate response", comment: "Generate sampling response button"), systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            presentation.errorMessage != nil ||
                            store.samplingModelName == nil
                        )

                        if store.samplingModelName == nil {
                            Text(NSLocalizedString("No LLM model is configured for sampling.", comment: "Sampling model missing message"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(NSLocalizedString("Deny", comment: "Deny sampling request")) { store.respondToSampling(.cancel) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    HStack {
                        Button {
                            store.respondToSampling(.allow(responseText: presentation.responseText))
                        } label: {
                            Label(NSLocalizedString("Send to server", comment: "Send sampling response to server"), systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Spacer()

                        Button(NSLocalizedString("Deny", comment: "Deny sampling request")) { store.respondToSampling(.cancel) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

#Preview {
    MCPSamplingView()
}