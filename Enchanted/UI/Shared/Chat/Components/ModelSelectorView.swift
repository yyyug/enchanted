//
import SwiftUI

struct ModelSelectorView: View {
    var modelsList: [LanguageModelSD]
    var selectedModel: LanguageModelSD?
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> ()
    var showChevron = true
    @State private var showModelSheet = false
    
    var body: some View {
        Group {
#if os(iOS) || os(visionOS)
            Button(action: { showModelSheet = true }) {
                HStack(alignment: .center, spacing: 8) {
                    if let selectedModel = selectedModel {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedModel.prettyName)
                                .font(.body)
                                .foregroundColor(Color.labelCustom)
                            Text(selectedModel.prettyVersion)
                                .font(.caption)
                                .foregroundColor(Color.gray3Custom)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10)
                        .foregroundColor(Color(.label))
                        .showIf(showChevron)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showModelSheet) {
                ModelSelectionSheet(modelsList: modelsList, selectedModel: selectedModel, onSelectModel: onSelectModel)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
#else
            Menu {
                ForEach(modelsList, id: \.self) { model in
                    Button(action: {
                        withAnimation(.easeOut) {    
                            onSelectModel(model)
                        }
                    }) {
                        Text(model.name)
                            .font(.body)
                            .tag(model.name)
                    }
                }
            } label: {
                HStack(alignment: .center) {
                    if let selectedModel = selectedModel {
                        HStack(alignment: .bottom, spacing: 5) {
                            Text(selectedModel.name)
                                .font(.body)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10)
                        .foregroundColor(Color(.label))
                        .showIf(showChevron)
                }
            }
#endif
        }
    }
}

struct ModelSelectionSheet: View {
    var modelsList: [LanguageModelSD]
    var selectedModel: LanguageModelSD?
    var onSelectModel: @MainActor (_ model: LanguageModelSD?) -> ()
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(modelsList, id: \.self) { model in
                    Button(action: {
                        onSelectModel(model)
                        dismiss()
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.prettyName)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(model.prettyVersion)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedModel?.id == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(NSLocalizedString("Select Model", comment: "Model selection sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel button")) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ModelSelectorView(
        modelsList: LanguageModelSD.sample,
        selectedModel: LanguageModelSD.sample[0], 
        onSelectModel: {_ in},
        showChevron: false
    )
}