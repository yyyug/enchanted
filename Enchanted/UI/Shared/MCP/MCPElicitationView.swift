//
//  MCPElicitationView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/09/2026.
//

import SwiftUI

struct MCPElicitationView: View {
    @ObservedObject private var store = MCPServerStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var stringValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Group {
                if let presentation = store.pendingElicitation {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            form(presentation)
                                .padding(20)
                        }
                        Divider()
                        footer(presentation)
                            .padding(16)
                    }
                } else {
                    EmptyView()
                }
            }
            .navigationTitle(NSLocalizedString("Information Request", comment: "MCP elicitation sheet title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(maxWidth: 700)
        .frame(minWidth: 420, minHeight: 460)
    }

    private func form(_ presentation: MCPElicitationPresentation) -> some View {
        let request = presentation.request

        return VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("%@ needs some information", comment: "MCP elicitation request header"),
                    request.serverName
                ))
                .font(.headline)
            } icon: {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(.accentColor)
            }

            Text(request.message)
                .font(.body)
                .textSelection(.enabled)

            if let schema = request.schema {
                if schema.properties.isEmpty {
                    Text(NSLocalizedString("This request does not specify any fields.", comment: "Empty elicitation schema message"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(schema.properties, id: \.name) { field in
                            fieldView(field, schema: schema)
                        }
                    }
                    .onAppear(perform: seedDefaults)
                }
            } else {
                Text(NSLocalizedString("This request does not include a field schema.", comment: "Missing elicitation schema message"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func fieldView(_ field: MCPElicitationField, schema: MCPElicitationSchema) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.title ?? field.name)
                    .font(.subheadline)
                if schema.required.contains(field.name) {
                    Text("*")
                        .foregroundColor(.red)
                }
            }

            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !field.enumValues.isEmpty {
                Picker(field.title ?? field.name, selection: enumBinding(for: field)) {
                    Text(NSLocalizedString("Select an option", comment: "Elicitation picker placeholder")).tag("").foregroundColor(.secondary)
                    ForEach(Array(field.enumValues.enumerated()), id: \.element) { _, value in
                        Text(value).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } else if field.type == "boolean" {
                Toggle(field.title ?? field.name, isOn: boolBinding(for: field))
                    .labelsHidden()
            } else {
                TextField(field.title ?? field.name, text: stringBinding(for: field))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
#if os(iOS)
                    .keyboardType(field.type == "integer" || field.type == "number" ? .numbersAndPunctuation : .default)
                    .autocapitalization(.none)
#endif
            }

            if let error = fieldError(field, schema: schema) {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
    }

    private func footer(_ presentation: MCPElicitationPresentation) -> some View {
        HStack {
            Button(NSLocalizedString("Submit", comment: "Submit elicitation form")) {
                guard let schema = presentation.request.schema else { return }
                let payload = makePayload(schema: schema)
                store.respondToElicitation(.submit(payload))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!formIsValid(presentation))

            Spacer()

            Button(NSLocalizedString("Decline", comment: "Decline elicitation request")) {
                store.respondToElicitation(.decline)
            }
            .buttonStyle(.bordered)

            Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
                store.respondToElicitation(.cancel)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Bindings & state

    private func stringBinding(for field: MCPElicitationField) -> Binding<String> {
        Binding(
            get: { stringValues[field.name] ?? "" },
            set: { stringValues[field.name] = $0 }
        )
    }

    private func boolBinding(for field: MCPElicitationField) -> Binding<Bool> {
        Binding(
            get: { boolValues[field.name] ?? false },
            set: { boolValues[field.name] = $0 }
        )
    }

    private func enumBinding(for field: MCPElicitationField) -> Binding<String> {
        Binding(
            get: { stringValues[field.name] ?? "" },
            set: { stringValues[field.name] = $0 }
        )
    }

    private func seedDefaults() {
        guard !initialized, let schema = store.pendingElicitation?.request.schema else { return }
        for field in schema.properties {
            if field.type == "boolean" {
                if let value = field.defaultValue as? NSNumber {
                    boolValues[field.name] = value.boolValue
                } else if let value = field.defaultValue as? Bool {
                    boolValues[field.name] = value
                }
            } else {
                if let value = field.defaultValue as? String {
                    stringValues[field.name] = value
                } else if let value = field.defaultValue as? NSNumber {
                    stringValues[field.name] = value.stringValue
                }
            }
        }
        initialized = true
    }

    private func makePayload(schema: MCPElicitationSchema) -> [String: Any] {
        var payload: [String: Any] = [:]
        for field in schema.properties {
            if field.type == "boolean" {
                payload[field.name] = boolValues[field.name] ?? false
            } else if field.type == "integer" {
                if let raw = stringValues[field.name], !raw.isEmpty, let number = Int(raw) {
                    payload[field.name] = number
                }
            } else if field.type == "number" {
                if let raw = stringValues[field.name], !raw.isEmpty, let number = Double(raw) {
                    payload[field.name] = number
                }
            } else {
                if let raw = stringValues[field.name] {
                    payload[field.name] = raw
                }
            }
        }
        return payload
    }

    // MARK: - Validation

    private func formIsValid(_ presentation: MCPElicitationPresentation) -> Bool {
        guard let schema = presentation.request.schema, !schema.properties.isEmpty else {
            return true
        }
        for field in schema.properties {
            if fieldError(field, schema: schema) != nil {
                return false
            }
        }
        return true
    }

    private func fieldError(_ field: MCPElicitationField, schema: MCPElicitationSchema) -> String? {
        if field.type == "boolean" {
            return nil
        }

        if !field.enumValues.isEmpty {
            if schema.required.contains(field.name) && (stringValues[field.name] ?? "").isEmpty {
                return NSLocalizedString("Required", comment: "Required field error")
            }
            return nil
        }

        let raw = stringValues[field.name] ?? ""
        let isEmpty = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if schema.required.contains(field.name) && isEmpty {
            return NSLocalizedString("Required", comment: "Required field error")
        }
        if isEmpty {
            return nil
        }

        if field.type == "integer" {
            guard let number = Int(raw) else {
                return NSLocalizedString("Must be a whole number", comment: "Integer validation error")
            }
            if let minimum = field.minimum, Double(number) < minimum {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Must be at least %@", comment: "Minimum integer validation error"),
                    NSNumber(value: minimum)
                )
            }
            if let maximum = field.maximum, Double(number) > maximum {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Must be at most %@", comment: "Maximum integer validation error"),
                    NSNumber(value: maximum)
                )
            }
            return nil
        }

        if field.type == "number" {
            guard let number = Double(raw) else {
                return NSLocalizedString("Must be a number", comment: "Number validation error")
            }
            if let minimum = field.minimum, number < minimum {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Must be at least %@", comment: "Minimum number validation error"),
                    NSNumber(value: minimum)
                )
            }
            if let maximum = field.maximum, number > maximum {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Must be at most %@", comment: "Maximum number validation error"),
                    NSNumber(value: maximum)
                )
            }
            return nil
        }

        if field.type == "string" {
            if let minLength = field.minLength, raw.count < minLength {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Must be at least %d characters", comment: "Minimum length validation error"),
                    minLength
                )
            }
            if let maxLength = field.maxLength, raw.count > maxLength {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Must be at most %d characters", comment: "Maximum length validation error"),
                    maxLength
                )
            }
            if field.format == "email", !isValidEmail(raw) {
                return NSLocalizedString("Must be a valid email address", comment: "Email validation error")
            }
            if field.format == "uri" || field.format == "url", URL(string: raw) == nil {
                return NSLocalizedString("Must be a valid URL", comment: "URL validation error")
            }
        }

        return nil
    }

    private func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }
}

#Preview {
    MCPElicitationView()
}