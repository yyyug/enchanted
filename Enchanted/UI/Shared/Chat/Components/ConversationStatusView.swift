//
//  ConversationStatusView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI
import ActivityIndicatorView

struct ConversationStatusView: View {
    var state: ConversationState
    var body: some View {
        switch state {
        case .loading(let message):
            if let message = message {
                HStack(spacing: 6) {
                    ProgressView()
                    Text(message)
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                EmptyView()
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
