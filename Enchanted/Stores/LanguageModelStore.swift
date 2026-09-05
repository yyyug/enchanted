//
//  ModelStore.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import SwiftData

@Observable
final class LanguageModelStore {
    static let shared = LanguageModelStore(swiftDataService: SwiftDataService.shared)

    private var swiftDataService: SwiftDataService
    @MainActor var models: [LanguageModelSD] = []
    @MainActor var supportsImages = false
    @MainActor var selectedModel: LanguageModelSD?

    init(swiftDataService: SwiftDataService) {
        self.swiftDataService = swiftDataService
    }

    @MainActor
    func setModel(model: LanguageModelSD?) {
        if let model = model {
            // check if model still exists
            if models.contains(model) {
                selectedModel = model
            }
        } else {
            selectedModel = nil
        }
    }

    @MainActor
    func setModel(modelName: String) {
        for model in models {
            if model.name == modelName {
                setModel(model: model)
                return
            }
        }
        if let lastModel = models.last {
            setModel(model: lastModel)
        }
    }

    func loadModels() async throws {
        let activeProvider = UserDefaults.standard.string(forKey: "activeProvider") ?? "ollama"
        var allRemoteModels: [LanguageModel] = []

        // Load Ollama models
        do {
            let ollamaModels = try await OllamaService.shared.getModels()
            allRemoteModels.append(contentsOf: ollamaModels)
        } catch {
            print("Failed to load Ollama models: \(error)")
        }

        // Load OpenAI models
        do {
            let openAIModels = try await OpenAIService.shared.getModels()
            allRemoteModels.append(contentsOf: openAIModels)
        } catch {
            print("Failed to load OpenAI models: \(error)")
        }

        // Save all models to SwiftData
        let modelsToSave = allRemoteModels.map { model in
            LanguageModelSD(name: model.name, imageSupport: model.imageSupport, modelProvider: model.provider)
        }
        try await swiftDataService.saveModels(models: modelsToSave)

        let storedModels = (try? await swiftDataService.fetchModels()) ?? []

        DispatchQueue.main.async {
            let remoteModelNames = allRemoteModels.map { $0.name }
            self.models = storedModels.filter { remoteModelNames.contains($0.name) }

            // If no model is selected, select the first one
            if self.selectedModel == nil, let firstModel = self.models.first {
                self.selectedModel = firstModel
            }
        }
    }

    func deleteAllModels() async throws {
        DispatchQueue.main.async {
            self.models = []
        }
        try await swiftDataService.deleteModels()
    }
}
