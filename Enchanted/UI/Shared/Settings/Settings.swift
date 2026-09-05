//
//  Settings.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 28/12/2023.
//

import SwiftUI
import Combine

struct Settings: View {
    var languageModelStore = LanguageModelStore.shared
    var conversationStore = ConversationStore.shared
    var swiftDataService = SwiftDataService.shared

    @AppStorage("ollamaUri") private var ollamaUri: String = ""
    @AppStorage("systemPrompt") private var systemPrompt: String = ""
    @AppStorage("vibrations") private var vibrations: Bool = true
    @AppStorage("colorScheme") private var colorScheme = AppColorScheme.system
    @AppStorage("defaultOllamaModel") private var defaultOllamaModel: String = ""
    @AppStorage("ollamaBearerToken") private var ollamaBearerToken: String = ""
    @AppStorage("appUserInitials") private var appUserInitials: String = ""
    @AppStorage("pingInterval") private var pingInterval: String = "5"
    @AppStorage("voiceIdentifier") private var voiceIdentifier: String = ""
    @AppStorage("activeProvider") private var activeProviderString: String = "ollama"

    private var activeProvider: ModelProvider {
        get {
            activeProviderString == "openAI" ? .openAI : .ollama
        }
        set {
            activeProviderString = newValue == .openAI ? "openAI" : "ollama"
        }
    }
    @AppStorage("openAIBaseURL") private var openAIBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("openAIApiKey") private var openAIApiKey: String = ""

    @StateObject private var speechSynthesiser = SpeechSynthesizer.shared

    @Environment(\.presentationMode) var presentationMode

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var cancellable: AnyCancellable?

    private func save() {
#if os(iOS)
#endif
        // remove trailing slash
        if ollamaUri.last == "/" {
            ollamaUri = String(ollamaUri.dropLast())
        }
        if openAIBaseURL.last == "/" {
            openAIBaseURL = String(openAIBaseURL.dropLast())
        }

        OllamaService.shared.initEndpoint(url: ollamaUri, bearerToken: ollamaBearerToken)
        OpenAIService.shared.configure(baseURL: openAIBaseURL, apiKey: openAIApiKey)

        Task {
            Haptics.shared.mediumTap()
            try? await languageModelStore.loadModels()
        }
        presentationMode.wrappedValue.dismiss()
    }

    private func checkServer() {
        Task {
            OllamaService.shared.initEndpoint(url: ollamaUri)
            OpenAIService.shared.configure(baseURL: openAIBaseURL, apiKey: openAIApiKey)

            if activeProvider == .ollama {
                ollamaStatus = await OllamaService.shared.reachable()
            } else {
                ollamaStatus = await OpenAIService.shared.reachable()
            }
            try? await languageModelStore.loadModels()
        }
    }

    private func deleteAll() {
        Task {
            try? await conversationStore.deleteAllConversations()
            try? await languageModelStore.deleteAllModels()
        }
    }

    @State var ollamaStatus: Bool?
    var body: some View {
        SettingsView(
            ollamaUri: $ollamaUri,
            systemPrompt: $systemPrompt,
            vibrations: $vibrations,
            colorScheme: $colorScheme,
            defaultOllamModel: $defaultOllamaModel,
            ollamaBearerToken: $ollamaBearerToken,
            appUserInitials: $appUserInitials,
            pingInterval: $pingInterval,
            voiceIdentifier: $voiceIdentifier,
            activeProvider: $activeProviderString,
            openAIBaseURL: $openAIBaseURL,
            openAIApiKey: $openAIApiKey,
            save: save,
            checkServer: checkServer,
            deleteAll: deleteAll,
            ollamaLangugeModels: languageModelStore.models,
            voices: speechSynthesiser.voices
        )
        .frame(maxWidth: 700)
        #if os(visionOS)
        .frame(minWidth: 600, minHeight: 800)
        #endif
        .onChange(of: defaultOllamaModel) { _, modelName in
            languageModelStore.setModel(modelName: modelName)
        }
        .onChange(of: activeProvider) { _, _ in
            Task {
                try? await languageModelStore.loadModels()
            }
        }
        .onAppear {
            /// refresh voices in the background
            cancellable = timer.sink { _ in
                speechSynthesiser.fetchVoices()
            }
        }
        .onDisappear {
            cancellable?.cancel()
        }
    }
}

#Preview {
    Settings()
}
