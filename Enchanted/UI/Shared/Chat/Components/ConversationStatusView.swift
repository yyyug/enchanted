//
//  ConversationStatusView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI
import ActivityIndicatorView

struct ConversationStatusView: View {
    @ObservedObject private var mcpStore = MCPServerStore.shared

    var state: ConversationState
    var onCancel: (() -> Void)? = nil
    var body: some View {
        switch state {
        case .loading(let message):
            VStack(alignment: .leading, spacing: 4) {
                if let message = message {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(message)
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let onCancel {
                            Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .destructive) { onCancel() }
                                .buttonStyle(.borderless)
                                .font(.footnote)
                                .accessibilityLabel(NSLocalizedString("Cancel", comment: "Cancel button"))
                        }
                    }
                }
                if let progress = mcpStore.progress {
                    VStack(alignment: .leading, spacing: 3) {
                        if let progressMessage = progress.message, !progressMessage.isEmpty {
                            Text(progressMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                }
            }
        case .completed: EmptyView()
        case .error(let message): HStack {
            Text(message)
                .foregroundColor(.red)
                .font(.callout)
            Spacer()
        }
        }
        
    }
}

#Preview {
    Group {
        ConversationStatusView(state: .loading())
        ConversationStatusView(state: .completed)
        ConversationStatusView(state: .error(message: "Could not connect"))
    }.previewLayout(.sizeThatFits)
}
