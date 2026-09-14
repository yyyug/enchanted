//
//  ChatView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 09/12/2023.
//

#if os(iOS)
import SwiftUI
import PhotosUI
import UIKit

struct ChatView: View {
    var conversation: ConversationSD?
    var messages: [MessageSD]
    var modelsList: [LanguageModelSD]
    var onMenuTap: () -> ()
    var onNewConversationTap: () -> ()
    var onSendMessageTap: @MainActor (_ prompt: String, _ model: LanguageModelSD, _ image: Image?, _ trimmingMessageId: String?) -> ()
    var conversationState: ConversationState
    var onStopGenerateTap: @MainActor () -> ()
    var reachable: Bool
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> ()
    var userInitials: String
    
    private var selectedModel: LanguageModelSD?
    @State private var message = ""
    @State private var isRecording = false
    @State private var editMessage: MessageSD?
    @FocusState private var isFocusedInput: Bool
    @StateObject var speechRecognizer = SpeechRecognizer()
    
    /// Image selection
    @State private var pickerSelectorActive: PhotosPickerItem?
    @State private var selectedImage: Image?
    @State private var showCamera = false
    
    init(
        conversation: ConversationSD? = nil,
        messages: [MessageSD],
        modelsList: [LanguageModelSD],
        selectedModel: LanguageModelSD?,
        onSelectModel: @MainActor @escaping (_ model: LanguageModelSD?) -> (),
        onMenuTap: @escaping () -> Void,
        onNewConversationTap: @escaping () -> Void,
        onSendMessageTap: @MainActor @escaping (_ prompt: String, _ model: LanguageModelSD, _ image: Image?, _ trimmingMessageId: String?) -> Void,
        conversationState: ConversationState,
        onStopGenerateTap: @MainActor @escaping () -> Void,
        reachable: Bool,
        modelSupportsImages: Bool = false,
        userInitials: String
    ) {
        self.conversation = conversation
        self.messages = messages
        self.modelsList = modelsList
        self.onMenuTap = onMenuTap
        self.onNewConversationTap = onNewConversationTap
        self.onSendMessageTap = onSendMessageTap
        self.conversationState = conversationState
        self.onStopGenerateTap = onStopGenerateTap
        self.reachable = reachable
        self.onSelectModel = onSelectModel
        self.selectedModel = selectedModel
        self.userInitials = userInitials
    }
    
    private func onMessageSubmit() {
        Task {
            await Haptics.shared.mediumTap()
            
            guard let selectedModel = selectedModel else { return }
            
            await onSendMessageTap(
                message,
                selectedModel,
                selectedImage,
                editMessage?.id.uuidString
            )
            
            withAnimation {
                isFocusedInput = false
                editMessage = nil
                selectedImage = nil
                message = ""
            }
        }
    }

    /// VoiceOver "Magic Tap" (two-finger double tap).
    ///
    /// While idle it starts voice input immediately; while recording it stops
    /// and sends. This lets a VoiceOver user dictate and send a message with
    /// two gestures instead of locating the voice, stop and send buttons.
    private func handleMagicTap() {
        if isRecording {
            let transcript = speechRecognizer.transcript
            speechRecognizer.stopTranscribing()
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = transcript
            }
            isRecording = false
            Haptics.shared.mediumTap()
            onMessageSubmit()
            announce(NSLocalizedString("Sending message", comment: "VoiceOver announcement when sending"))
        } else {
            startVoiceInput()
        }
    }

    private func startVoiceInput() {
        Task {
            await speechRecognizer.userInit()
            // The magic tap gives explicit start/stop control, so silence
            // auto-stop is disabled for these sessions.
            speechRecognizer.onAutoStop = nil
            speechRecognizer.resetTranscript()
            speechRecognizer.startTranscribing(onUpdate: { transcription in
                self.message = transcription
            })
            isRecording = true
            Haptics.shared.mediumTap()
            announce(NSLocalizedString("Listening", comment: "VoiceOver announcement when listening"))
        }
    }

    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
    
    var header: some View {
        HStack(alignment: .center) {
            Button(action: onMenuTap) {
                Image(systemName: "line.3.horizontal")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundColor(Color(.label))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(NSLocalizedString("Menu", comment: "Menu button"))
            .accessibilityHint(NSLocalizedString("Opens conversation history and settings", comment: "Menu button hint"))
            .accessibilityAddTraits(.isButton)

            Spacer()

            ModelSelectorView(
                modelsList: modelsList,
                selectedModel: selectedModel,
                onSelectModel: onSelectModel
            )
            .showIf(!modelsList.isEmpty)
            .accessibilitySortPriority(1)

            Spacer()

            HStack(spacing: 16) {
                if !conversationMarkdown.isEmpty {
                    ShareLink(item: conversationMarkdown) {
                        Image(systemName: "square.and.arrow.up")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .foregroundColor(Color(.label))
                    }
                    .accessibilityLabel(NSLocalizedString("Share conversation", comment: "Share conversation button"))
                }

                Button(action: onNewConversationTap) {
                    Image(systemName: "square.and.pencil")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundColor(Color(.label))
                }
                .accessibilityLabel(NSLocalizedString("New Conversation", comment: "New conversation button"))
                .accessibilitySortPriority(0)
            }
        }
    }

    /// Markdown rendering of the conversation, used by the share sheet.
    private var conversationMarkdown: String {
        messages
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { message in
                let speaker = message.role == "user" ? "User" : "Assistant"
                return "**\(speaker)**\n\n\(message.content)"
            }
            .joined(separator: "\n\n---\n\n")
    }
    
    var inputFields: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $pickerSelectorActive) {
                Image(systemName: "paperclip")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.foreground)
                    .frame(width: 22, height: 22)
                    .frame(width: 44, height: 44)
            }
            .onChange(of: pickerSelectorActive) {
                Task {
                    if let loaded = try? await pickerSelectorActive?.loadTransferable(type: Image.self) {
                        selectedImage = loaded
                    } else {
                        print("Failed")
                    }
                }
            }
            .showIf(selectedModel?.supportsImages ?? false)
            .accessibilityLabel(NSLocalizedString("Attach", comment: "Attach image button"))

            if (selectedModel?.supportsImages ?? false), UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Image(systemName: "camera")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.foreground)
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(NSLocalizedString("Take Photo", comment: "Camera capture button"))
            }


            HStack(spacing: 4) {
                SelectedImageView(image: $selectedImage)

                TextField(NSLocalizedString("Type a message...", comment: "Message input placeholder"), text: $message, axis: .vertical)
                    .focused($isFocusedInput)
                    .frame(minHeight: 44)
                    .font(.body)

                RecordingView(speechRecognizer: speechRecognizer, isRecording: $isRecording.animation()) { transcription in
                    self.message = transcription
                }
            }
            .onChange(of: isFocusedInput, { oldValue, newValue in
                withAnimation {
                    isFocusedInput = newValue
                }
            })
            .padding(.horizontal, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(
                        isRecording ? Color(.systemBlue) : Color(.systemGray2),
                        style: StrokeStyle(lineWidth: isRecording ? 2 : 0.5)
                    )
            )

            switch conversationState {
            case .loading:
                SimpleFloatingButton(systemImage: "square.fill", onClick: onStopGenerateTap)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(NSLocalizedString("Stop", comment: "Stop generation button"))
            default:
                SimpleFloatingButton(systemImage: "paperplane.fill", onClick: onMessageSubmit)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(NSLocalizedString("Send", comment: "Send message button"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // allow focusing text area on greater tap area
            isFocusedInput = true
        }
    }
    
    var body: some View {
        VStack {
            header
                .padding(.horizontal)
            
            if conversation != nil {
                MessageListView(
                    messages: messages,
                    conversationState: conversationState,
                    userInitials: userInitials,
                    editMessage: $editMessage
                )
            } else {
                EmptyConversaitonView(sendPrompt: {selectedMessage in
                    if let selectedModel = selectedModel {
                        onSendMessageTap(selectedMessage, selectedModel, nil, nil)
                    }
                })
            }
            
            ConversationStatusView(state: conversationState, onCancel: { onStopGenerateTap() })
                .padding()
            
            if !reachable {
                UnreachableAPIView()
            }
            
            inputFields
                .padding(.horizontal)
            
        }
        .padding(.bottom, 5)
        .onChange(of: editMessage, initial: false) { _, newMessage in
            if let newMessage = newMessage {
                message = newMessage.content
                isFocusedInput = true
            }
        }
        .accessibilityAction(.magicTap) {
            handleMagicTap()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                selectedImage = image
            }
            .ignoresSafeArea()
        }
    }
}

/// Minimal camera capture wrapper. Only presented when a camera is available.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onImage: (Image) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.onImage(Image(uiImage: uiImage))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#Preview {
    ChatView(
        conversation: ConversationSD.sample[0],
        messages: MessageSD.sample,
        modelsList: LanguageModelSD.sample,
        selectedModel: LanguageModelSD.sample[0],
        onSelectModel: {_ in },
        onMenuTap: {},
        onNewConversationTap: { },
        onSendMessageTap: {_,_,_,_    in},
        conversationState: .loading(),
        onStopGenerateTap: {},
        reachable: false,
        modelSupportsImages: true, 
        userInitials: "AM"
    )
}

#Preview {
    ChatView(
        conversation: nil,
        messages: [],
        modelsList: LanguageModelSD.sample,
        selectedModel: LanguageModelSD.sample[0],
        onSelectModel: {_ in},
        onMenuTap: {},
        onNewConversationTap: { },
        onSendMessageTap: {_,_,_,_    in},
        conversationState: .completed,
        onStopGenerateTap: {},
        reachable: true,
        modelSupportsImages: true,
        userInitials: "AM"
    )
}
#endif
