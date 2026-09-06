//
//  SettingsView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 11/12/2023.
//

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    @Binding var ollamaUri: String
    @Binding var systemPrompt: String
    @Binding var vibrations: Bool
    @Binding var colorScheme: AppColorScheme
    @Binding var defaultOllamModel: String
    @Binding var ollamaBearerToken: String
    @Binding var appUserInitials: String
    @Binding var pingInterval: String
    @Binding var autoSpeak: Bool
    @Binding var voiceIdentifier: String
    @Binding var activeProvider: String
    @Binding var openAIBaseURL: String
    @Binding var openAIApiKey: String
    @State var ollamaStatus: Bool?
    var save: () -> ()
    var checkServer: () -> ()
    var deleteAll: () -> ()
    var ollamaLangugeModels: [LanguageModelSD]
    var voices: [AVSpeechSynthesisVoice]

    @State private var deleteConversationsDialog = false
    
    var body: some View {
        VStack {
            ZStack {
                HStack {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Text("Cancel", comment: "Cancel button")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(.label))
                    }


                    Spacer()

                    Button(action: save) {
                        Text("Save", comment: "Save button")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(.label))
                    }
                }

                HStack {
                    Spacer()
                    Text("Settings", comment: "Settings title")
                        .font(.system(size: 16))
                        .fontWeight(.medium)
                        .foregroundStyle(Color(.label))
                    Spacer()
                }
            }
            .padding()
            
            Form {
                Section(header: Text("Provider", comment: "Provider section").font(.headline)) {
                    Picker("Provider", selection: $activeProvider) {
                        Text("OpenAI Compatible", comment: "OpenAI provider").tag("openAI")
                        Text("Ollama", comment: "Ollama provider").tag("ollama")
                    }
                    .pickerStyle(.segmented)
                }

                if activeProvider == "ollama" {
                    Section(header: Text("Ollama", comment: "Ollama section").font(.headline)) {

                        TextField("Ollama server URI", text: $ollamaUri, onCommit: checkServer)
                            .textContentType(.URL)
                            .disableAutocorrection(true)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .accessibilityLabel(NSLocalizedString("Ollama server URI", comment: "Ollama URI label"))
    #if !os(macOS)
                            .padding(.top, 8)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
    #endif

                        TextField("Bearer Token", text: $ollamaBearerToken)
                            .disableAutocorrection(true)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .accessibilityLabel(NSLocalizedString("Bearer Token", comment: "Bearer token label"))
    #if os(iOS)
                            .autocapitalization(.none)
    #endif
                        TextField("Ping Interval (seconds)", text: $pingInterval)
                            .disableAutocorrection(true)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .accessibilityLabel(NSLocalizedString("Ping Interval", comment: "Ping interval label"))
                    }
                } else {
                    Section(header: Text("OpenAI Compatible", comment: "OpenAI section").font(.headline)) {

                        TextField("Base URL", text: $openAIBaseURL, onCommit: checkServer)
                            .textContentType(.URL)
                            .disableAutocorrection(true)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
    #if !os(macOS)
                            .padding(.top, 8)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
    #endif

                        SecureField("API Key", text: $openAIApiKey)
                            .disableAutocorrection(true)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
    #if os(iOS)
                            .autocapitalization(.none)
    #endif

                        Text("Supports any OpenAI-compatible API (OpenAI, Together, Groq, OpenRouter, local servers, etc.)", comment: "OpenAI compatible info")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Model Settings", comment: "Model settings section").font(.headline)) {
                    VStack(alignment: .leading) {
                        Text("System prompt", comment: "System prompt label")
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 13))
                            .cornerRadius(4)
                            .multilineTextAlignment(.leading)
                            .frame(minHeight: 100)
                    }

                    Picker(selection: $defaultOllamModel) {
                        ForEach(ollamaLangugeModels, id:\.self) { model in
                            Text(model.name).tag(model.name)
                        }
                    } label: {
                        Label {
                            Text("Default Model", comment: "Default model label")
                        } icon: {
                            Image(activeProvider == "ollama" ? "ollama" : "brain")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(Color(.label))
                                .frame(width: 24, height: 24)
                        }
                    }
                }

                Section(header: Text("APP", comment: "App section").font(.headline).padding(.top, 20)) {

#if os(iOS)
                    Toggle(isOn: $vibrations, label: {
                        Label("Vibrations", systemImage: "water.waves")
                            .foregroundStyle(Color.label)
                    })
#endif
                }


                Picker(selection: $colorScheme) {
                    ForEach(AppColorScheme.allCases, id:\.self) { scheme in
                        Text(scheme.localizedName).tag(scheme.id)
                    }
                } label: {
                    Label("Appearance", systemImage: "sun.max")
                        .foregroundStyle(Color.label)
                }

                Toggle(isOn: $autoSpeak, label: {
                    Label("Auto-speak Responses", systemImage: "speaker.wave.2")
                        .foregroundStyle(Color.label)
                })

                Picker(selection: $voiceIdentifier) {
                    ForEach(voices, id:\.self.identifier) { voice in
                        Text(voice.prettyName).tag(voice.identifier)
                    }
                } label: {
                    Label("Voice", systemImage: "waveform")
                        .foregroundStyle(Color.label)

#if os(macOS)
                    Text("Download voices by going to Settings > Accessibility > Spoken Content > System Voice > Manage Voices.", comment: "Voice download info macOS")
#else
                    Text("Download voices by going to Settings > Accessibility > Spoken Content > Voices.", comment: "Voice download info iOS")
#endif

                    Button(action: {
#if os(macOS)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems") {
                            NSWorkspace.shared.open(url)
                        }
#else
                        let url = URL(string: "App-Prefs:root=General&path=ACCESSIBILITY")
                        if let url = url, UIApplication.shared.canOpenURL(url) {
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        }
#endif

                    }) {

                        Text("Open Settings", comment: "Open settings button")
                    }
                    .buttonStyle(PlainButtonStyle())
                }


                TextField("Initials", text: $appUserInitials)
                    .disableAutocorrection(true)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
#if os(iOS)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
#endif

                Button(action: {deleteConversationsDialog.toggle()}) {
                    HStack {
                        Spacer()

                        Text("Clear All Data", comment: "Clear data button")
                            .foregroundStyle(Color(.systemRed))
                            .padding(.vertical, 6)

                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .preferredColorScheme(colorScheme.toiOSFormat)
        .confirmationDialog("Delete All Conversations?", isPresented: $deleteConversationsDialog) {
            Button("Delete", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Delete All Conversations?", comment: "Delete confirmation")
        }
    }
}

#Preview {
    SettingsView(
        ollamaUri: .constant(""),
        systemPrompt: .constant("You are an intelligent assistant solving complex problems. You are an intelligent assistant solving complex problems. You are an intelligent assistant solving complex problems."),
        vibrations: .constant(true),
        colorScheme: .constant(.light),
        defaultOllamModel: .constant("llama2"),
        ollamaBearerToken: .constant("x"),
        appUserInitials: .constant("AM"),
        pingInterval: .constant("5"),
         autoSpeak: .constant(false),
         voiceIdentifier: .constant("sample"),
        activeProvider: .constant("ollama"), 
        openAIBaseURL: .constant("https://api.openai.com/v1"),
        openAIApiKey: .constant(""),
        save: {},
        checkServer: {},
        deleteAll: {},
        ollamaLangugeModels: LanguageModelSD.sample,
        voices: []
    )
}

