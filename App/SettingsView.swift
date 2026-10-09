import SwiftUI
import AgentKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.autoApproveKey) private var autoApproveMedium = false
    @AppStorage(AppModel.modelKey) private var modelName = AppModel.defaultModel
    @State private var keyInput = ""
    @State private var keyStored = false
    @State private var confirmYolo = false
#if !FLIPPERHERO_STORE
    @State private var showArmSheet = false
#endif
    @AppStorage(AppModel.autoConnectKey) private var autoConnect = true
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(keyStored ? "Key stored (enter a new one to replace)" : "sk-or-...", text: $keyInput)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save key") {
                        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.count >= 30 else {
                            saveError = String(localized: "That is only \(trimmed.count) characters. An OpenRouter key (sk-or-v1-...) is much longer. The paste may have been cut off.")
                            return
                        }
                        let status = KeychainStore.write(trimmed, account: "openrouter")
                        keyStored = model.hasAPIKey
                        if status == errSecSuccess && keyStored {
                            saveError = nil
                            keyInput = ""
                            model.newChat()
                        } else {
                            saveError = String(localized: "Could not save the key (Keychain status \(status)). It is still in the field, nothing was lost.")
                        }
                    }.disabled(keyInput.isEmpty)
                    if let saveError {
                        Text(saveError).font(.footnote).foregroundStyle(Theme.danger)
                    }
                    if keyStored {
                        LabeledContent("Stored key", value: model.isDemo ? "sk-or-v1...  (demo)" : Self.keySummary())
                        Button("Remove key", role: .destructive) {
                            KeychainStore.write("", account: "openrouter")
                            keyStored = false
                            model.newChat()
                        }
                    }
                    TextField("Model", text: $modelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: { Text("OpenRouter") } footer: {
                    Text("The key stays in the iOS Keychain on this iPhone. Your messages and the file contents the agent reads are sent to the model provider.")
                }

                Section {
                    Toggle("Skip prompts for medium-risk actions", isOn: $autoApproveMedium)
                } header: { Text("Approvals") } footer: {
                    Text("High-risk actions (deleting, transmitting, emulating, anything that can run code) always ask unless YOLO mode is on. After the agent has read content from the Flipper, every change asks again, even with this switch on.")
                }

                Section {
                    Toggle("Connect to the last Flipper on launch", isOn: $autoConnect)
                } header: { Text("Connection") } footer: {
                    Text("Only while the app is open. If you disconnect by hand, it will not reconnect on its own until you connect again.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { model.yolo },
                        set: { on in if on { confirmYolo = true } else { model.yolo = false } }
                    )) {
                        Label("YOLO mode", systemImage: "flame.fill").foregroundStyle(model.yolo ? Theme.danger : .primary)
                    }
                    if model.yolo {
                        @Bindable var model = model
                        Toggle("Still ask after reading Flipper content", isOn: $model.yoloAsksAfterUntrusted)
                    }
                } header: { Text("YOLO") } footer: {
                    Text("The agent changes, deletes, transmits and emulates without asking. Blocked paths (internal storage, key files, top-level recursive deletes) stay blocked. Resets when the app restarts. With the second switch on, the agent still asks after it read files from your Flipper, which is when a planted instruction could trick it.")
                }

#if !FLIPPERHERO_STORE
                Section {
                    LabeledContent("Status", value: model.engagement.active
                        ? String(localized: "Armed (\(model.engagement.profile.summary))")
                        : String(localized: "Off"))
                    if model.engagement.active {
                        if !model.engagement.profile.note.isEmpty {
                            LabeledContent("Scope", value: model.engagement.profile.note)
                        }
                        Button("Disarm", role: .destructive) {
                            model.applyEngagement(.inactive, audit: true)
                        }
                    } else {
                        Button("Arm engagement mode...") { showArmSheet = true }
                    }
                } header: { Text("Engagement mode") } footer: {
                    Text("For authorized engagements: pre-approves actions for this session so the agent can work without a prompt per step. Blocked paths stay blocked, everything is audited, and it disarms on disconnect or app restart. The agent can request arming in chat, but only you can confirm it.")
                }
#endif

                Section {
                    NavigationLink("Audit log") { AuditView() }
                    Link("Privacy Policy", destination: URL(string: "https://github.com/flipper-hero/ios-app/blob/main/PRIVACY.md")!)
                    Link("Support on GitHub", destination: URL(string: "https://github.com/flipper-hero/ios-app/issues")!)
                }
            }
            .themedList()
            .brandedNavigation("Settings")
            .onAppear { keyStored = model.hasAPIKey }
#if !FLIPPERHERO_STORE
            .sheet(isPresented: $showArmSheet) { EngagementArmSheet() }
#endif
            .confirmationDialog("Enable YOLO mode?", isPresented: $confirmYolo, titleVisibility: .visible) {
                Button("Enable YOLO", role: .destructive) { model.yolo = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The agent will delete files, transmit radio signals and emulate cards without asking. A tampered file on the Flipper could mislead it. Only this session.")
            }
        }
    }
}

#if !FLIPPERHERO_STORE
/// The operator arms engagement mode here: capabilities, scope note, then a deliberate hold.
struct EngagementArmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var autoApprovals = true
    @State private var rawRPC = false
    @State private var autoBadKB = false
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Run actions without prompts", isOn: $autoApprovals)
                    Toggle("Raw device commands (rpc_raw)", isOn: $rawRPC)
                    Toggle("Start Bad KB scripts (badusb_execute)", isOn: $autoBadKB)
                } header: { Text("Capabilities") } footer: {
                    Text("Raw commands can reach anything the firmware exposes, including paths the normal tools protect. Started Bad KB scripts type into whatever machine the Flipper is plugged into.")
                }
                Section {
                    TextField("Scope note, e.g. client name or location", text: $note)
                } header: { Text("Scope") } footer: {
                    Text("Shown on the banner and given to the agent, so it can tell what is in scope.")
                }
                Section {
                    HoldToConfirm(label: String(localized: "Hold to arm")) {
                        model.applyEngagement(EngagementState(
                            active: true,
                            profile: EngagementProfile(autoApprovals: autoApprovals, rawRPC: rawRPC,
                                                       autoBadKB: autoBadKB, note: note),
                            startedAt: .now), audit: true)
                        dismiss()
                    }
                }
            }
            .themedList()
            .navigationTitle("Engagement mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif

extension SettingsView {
    /// Shows only the prefix and length, never the key itself.
    static func keySummary() -> String {
        guard let key = KeychainStore.read("openrouter") else { return "none" }
        return "\(key.prefix(6))...  (\(key.count) characters)"
    }
}

struct AuditView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.auditRecords) { record in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.summary).font(.subheadline)
                    Spacer()
                    Text(label(record.decision)).font(.caption).foregroundStyle(color(record))
                }
                Text(record.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                if !record.detail.isEmpty { Text(record.detail).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .overlay { if model.auditRecords.isEmpty { Text("No actions yet").foregroundStyle(.secondary) } }
        .themedList()
        .navigationTitle("Audit log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
#if !FLIPPERHERO_STORE
            if !model.auditRecords.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: EngagementReport.markdown(
                        records: model.auditRecords.reversed(), engagement: model.engagement)) {
                        Label("Export report", systemImage: "square.and.arrow.up")
                    }
                }
            }
#endif
        }
        .task { await model.loadAudit() }
    }

    private func label(_ decision: AuditRecord.Decision) -> String {
        switch decision {
        case .auto: String(localized: "automatic")
        case .yolo: String(localized: "YOLO")
        case .engaged: String(localized: "engaged")
        case .approved: String(localized: "approved")
        case .shortcut: String(localized: "Siri / Shortcuts")
        case .denied: String(localized: "denied")
        case .blocked: String(localized: "blocked")
        case .invalid: String(localized: "invalid")
        }
    }

    private func color(_ r: AuditRecord) -> Color {
        switch r.decision {
        case .denied, .blocked, .invalid, .yolo, .engaged: .red
        case .approved, .shortcut: .orange
        case .auto: .secondary
        }
    }
}
