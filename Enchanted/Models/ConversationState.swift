//
//  ConversationState.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation

enum ConversationState: Equatable {
    case loading(message: String? = nil)
    case completed
    case error(message: String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}
