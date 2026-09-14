//
//  ConversationHistoryList.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import SwiftUI

struct ConversationGroup: Hashable {
    let date: Date
    var conversations: [ConversationSD]
    
    // Implementing the Hashable protocol
    static func == (lhs: ConversationGroup, rhs: ConversationGroup) -> Bool {
        lhs.date == rhs.date
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
    }
}

struct ConversationHistoryList: View {
    var selectedConversation: ConversationSD?
    var conversations: [ConversationSD]
    var onTap: (_ conversation: ConversationSD) -> ()
    var onDelete: (_ conversation: ConversationSD) -> ()
    var onDeleteDailyConversations: (_ date: Date) -> ()

    @State private var searchText = ""

    /// Filters by conversation title and by message content.
    private var filteredConversations: [ConversationSD] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { conversation in
            if conversation.name.localizedCaseInsensitiveContains(query) {
                return true
            }
            return conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    func groupConversationsByDay(conversations: [ConversationSD]) -> [ConversationGroup] {
        let groupedDictionary = Dictionary(grouping: conversations) { (conversation) -> Date in
            return Calendar.current.startOfDay(for: conversation.updatedAt)
        }
        
        return groupedDictionary.map { (key, value) in
            ConversationGroup(date: key, conversations: value)
        }.sorted(by: { $0.date > $1.date })
    }
    
    var conversationGroups: [ConversationGroup] {
        groupConversationsByDay(conversations: filteredConversations)
    }
    
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            TextField(NSLocalizedString("Search conversations", comment: "Conversation search field"), text: $searchText)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
#if os(iOS)
                .autocapitalization(.none)
                .submitLabel(.search)
#endif
                .accessibilityLabel(NSLocalizedString("Search conversations", comment: "Conversation search field"))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Clear search", comment: "Clear search button"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            searchField

            if filteredConversations.isEmpty && !searchText.isEmpty {
                Text(NSLocalizedString("No conversations found", comment: "Empty search result"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(conversationGroups, id:\.self) { conversationGroup in
                
                HStack {
                    Text(conversationGroup.date.daysAgoString())
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Color(.systemGray))
                    
                    Spacer()
                }
                .contextMenu(menuItems: {
                    Button(role: .destructive, action: { onDeleteDailyConversations(conversationGroup.date) }) {
                        Label("Delete daily conversations", systemImage: "trash")
                    }
                })
#if os(iOS) || os(visionOS)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive, action: { onDeleteDailyConversations(conversationGroup.date) }) {
                        Label(NSLocalizedString("Delete All", comment: "Delete all conversations for this day"), systemImage: "trash")
                    }
                }
#endif
                
                ForEach(conversationGroup.conversations, id:\.self) { dailyConversation in
                    Button(action: {onTap(dailyConversation)}) {
                        HStack {
                            Circle()
                                .frame(width: 6, height: 6)
                                .animation(.easeOut(duration: 0.15))
                                .transition(.opacity)
                                .showIf(selectedConversation == dailyConversation)
                            
                            Text(dailyConversation.name)
                                .lineLimit(1)
                                .font(.body)
                                .foregroundColor(Color(.label))
                                .animation(.easeOut(duration: 0.15))
                                .transition(.opacity)
                            Spacer()
                        }
                        .animation(.easeOut(duration: 0.15))
                    }
                    .buttonStyle(.plain)
                    .contextMenu(menuItems: {
                        Button(role: .destructive, action: { onDelete(dailyConversation) }) {
                            Label("Delete", systemImage: "trash")
                        }
                    })
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(dailyConversation.name)
                    .accessibilityAddTraits(selectedConversation == dailyConversation ? .isSelected : [])
#if os(iOS) || os(visionOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive, action: { onDelete(dailyConversation) }) {
                            Label(NSLocalizedString("Delete", comment: "Delete conversation"), systemImage: "trash")
                        }
                    }
#endif
                }
                
                Divider()
            }
        }
    }
}


#Preview {
    ConversationHistoryList(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onTap: {_ in}, onDelete: {_ in}, onDeleteDailyConversations: {_ in})
}
