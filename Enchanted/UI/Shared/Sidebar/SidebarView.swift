//
import SwiftUI

struct SidebarView: View {
    @Environment(\.openWindow) var openWindow
    var selectedConversation: ConversationSD?
    var conversations: [ConversationSD]
    var onConversationTap: (_ conversation: ConversationSD) -> ()
    var onConversationDelete: (_ conversation: ConversationSD) -> ()
    var onDeleteDailyConversations: (_ date: Date) -> ()
    var onClose: (() -> ())?
    @State var showSettings = false
    @State var showCompletions = false
    @State var showKeyboardShortcutas = false
    
    private func onSettingsTap() {
        Task {
            showSettings.toggle()
            await Haptics.shared.mediumTap()
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
#if os(iOS) || os(visionOS)
            // Header with title and close button
            HStack {
                Text(NSLocalizedString("Conversations", comment: "Conversation history title"))
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(Color(.label))
                
                Spacer()
                
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(.label))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(NSLocalizedString("Close", comment: "Close sidebar button"))
                .accessibilityHint(NSLocalizedString("Returns to chat", comment: "Close sidebar hint"))
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            
            Divider()
#endif
            
            ScrollView() {
                ConversationHistoryList(
                    selectedConversation: selectedConversation,
                    conversations: conversations,
                    onTap: onConversationTap,
                    onDelete: onConversationDelete,
                    onDeleteDailyConversations: onDeleteDailyConversations
                )
            }
            .scrollIndicators(.never)
            
            Divider()
            
#if os(macOS)
            SidebarButton(title: "Completions", image: "textformat.abc", onClick: {showCompletions.toggle()})
            
            SidebarButton(title: "Shortcuts", image: "keyboard.fill", onClick: {showKeyboardShortcutas.toggle()})
#endif
            
            SidebarButton(title: "Settings", image: "gearshape.fill", onClick: onSettingsTap)
            
        }
        .padding(.bottom)
        .background(Color(.systemBackground))
#if os(macOS)
        .focusedSceneValue(\.showSettings, $showSettings)
#endif
        .sheet(isPresented: $showSettings) {
            Settings()
        }
#if os(macOS)
        .sheet(isPresented: $showCompletions) {
            CompletionsEditor()
        }
        .sheet(isPresented: $showKeyboardShortcutas) {
            KeyboardShortcutsDemo()
        }
#endif
        
    }
}

#Preview {
    SidebarView(selectedConversation: ConversationSD.sample[0], conversations: ConversationSD.sample, onConversationTap: {_ in}, onConversationDelete: {_ in}, onDeleteDailyConversations: {_ in})
}