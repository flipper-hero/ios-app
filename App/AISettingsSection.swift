import SwiftUI
import AgentKit

struct AISettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var keyInput = ""
    @State private var modelName = ""
    @State private var baseURL = ""
    @State private var keyStored = false
    @State private var isTesting = false
    @State private var loaded = false
    @State private var error: String?
    @State private var verified = false

    private var settings: AISettings {
        AISettings(provider: model.aiProvider, model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                   baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var candidateKey: String {
        let entered = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty ? KeychainStore.read(model.aiProvider.rawValue) ?? "" : entered
    }

    var body: some View {
        Section {
            Picker("Provider", selection: Binding(get: { model.aiProvider }, set: { model.selectProvider($0) })) {
                ForEach(AIProvider.allCases) { provider in Text(verbatim: provider.name).tag(provider) }
            }
            .accessibilityIdentifier("aiProviderPicker")
            .disabled(isTesting || model.isBusy)

            SecureField(keyStored ? String(localized: "Key stored (enter a new one to replace)") : String(localized: "API key"), text: $keyInput)
                .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("aiAPIKey")
                .disabled(isTesting || model.isBusy)

            NavigationLink {
                AIModelPicker(settings: settings, apiKey: candidateKey, isDemo: model.isDemo, selection: $modelName)
            } label: {
                HStack {
                    Text("Choose model")
                    Spacer()
                    if !modelName.isEmpty {
                        Text(verbatim: modelName).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .accessibilityIdentifier("aiModelSelector")
            .disabled(isTesting || model.isBusy)

            TextField("Model ID", text: $modelName)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("aiModelID")
                .disabled(isTesting || model.isBusy)

            DisclosureGroup("API base URL") {
                TextField("API base URL", text: $baseURL)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("aiBaseURL")
                    .disabled(isTesting || model.isBusy)
                Link("Provider documentation", destination: model.aiProvider.documentation)
            }

            Button {
                let proposed = settings
                let key = candidateKey
                isTesting = true
                error = nil
                verified = false
                Task {
                    defer { isTesting = false }
                    do {
                        try await proposed.verifyAndSave(key: key)
                        model.applyAISettings(proposed)
                        keyStored = true
                        keyInput = ""
                        verified = true
                    } catch {
                        self.error = (error as? ProviderError)?.description ?? error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    if isTesting { ProgressView().controlSize(.small) }
                    Text(isTesting ? String(localized: "Testing connection…") : String(localized: "Test and save"))
                }
            }
            .accessibilityIdentifier("aiTestAndSave")
            .disabled(isTesting || model.isBusy || modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || (!keyStored && keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || model.isDemo)

            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            if verified { Label("Connection verified", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
            if keyStored {
                Button("Remove key", role: .destructive) {
                    let status = KeychainStore.write("", account: model.aiProvider.rawValue)
                    guard status == errSecSuccess else {
                        error = String(localized: "Could not save the key (Keychain status \(status)). It is still in the field, nothing was lost.")
                        return
                    }
                    keyStored = false
                    verified = false
                    model.applyAISettings(model.aiSettings)
                }.disabled(isTesting || model.isBusy || model.isDemo)
            }
        } header: { Text("AI connection") } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("The key stays in the iOS Keychain on this iPhone. Your messages and the file contents the agent reads are sent to the model provider.")
                Text("Saving sends a short test message. Provider charges may apply. Each provider keeps its own key and model.")
                Text("Choose a model with tool calling. Images require vision support.")
            }
        }
        .onAppear { if !loaded { loadSettings(); loaded = true } }
        .onChange(of: model.aiProvider) { loadSettings() }
        .onChange(of: model.aiSettings) { if settings != model.aiSettings { loadSettings() } }
        .onChange(of: modelName) { verified = false; error = nil }
        .onChange(of: baseURL) { verified = false; error = nil }
        .onChange(of: keyInput) { if !keyInput.isEmpty { verified = false; error = nil } }
    }

    private func loadSettings() {
        let saved = model.aiSettings
        modelName = saved.model
        baseURL = saved.baseURL
        keyInput = ""
        keyStored = model.hasAPIKey
        verified = false
        error = nil
    }
}

private struct AIModelPicker: View {
    let settings: AISettings
    let apiKey: String
    let isDemo: Bool
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var models: [AIModel] = []
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?

    private var filtered: [AIModel] {
        models.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if loading { ProgressView("Loading models…") }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Link("Provider documentation", destination: settings.provider.documentation)
            }
            if !loading && error == nil && filtered.isEmpty { Text("No matching models") }
            ForEach(filtered) { item in
                Button {
                    selection = item.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.name).foregroundStyle(.primary)
                            if item.name != item.id { Text(verbatim: item.id).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if selection == item.id { Image(systemName: "checkmark").foregroundStyle(Theme.orange) }
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Choose model")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task {
            defer { loading = false }
            do {
                if isDemo {
                    models = [AIModel(id: settings.model, name: settings.model)]
                } else {
                    models = try await settings.api(key: apiKey).models()
                }
            } catch {
                self.error = (error as? ProviderError)?.description ?? error.localizedDescription
            }
        }
    }
}
