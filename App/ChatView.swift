import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var voice = VoiceInput()
    @State private var showCamera = false
    @State private var attachment: Data?
    @FocusState private var focused: Bool

    private var ready: Bool { model.isConnected && model.hasAPIKey }
    private var canSend: Bool {
        ready && !model.isBusy && (!input.trimmingCharacters(in: .whitespaces).isEmpty || attachment != nil)
    }

    /// Sent to the agent as typed, so they are in the user's language.
    private static let suggestions: [(String, String)] = [
        ("battery.100", String(localized: "How full are the battery and the SD card?")),
        ("cpu", String(localized: "Which firmware is my Flipper running?")),
        ("folder", String(localized: "Show me what is in /ext")),
        ("doc.text.magnifyingglass", String(localized: "Which NFC cards have I saved?")),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                Theme.glow
                VStack(spacing: 0) {
                    if !ready { notice }
#if !FLIPPERHERO_STORE
                    if model.engagement.active { EngagementBanner() }
#endif
                    if model.chat.isEmpty && !model.isBusy { emptyState } else { transcript }
                    composer
                }
            }
            .brandedNavigation("Agent")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { model.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                        Button {
                            model.setSpeakReplies(!model.speakReplies)
                        } label: {
                            Label(model.speakReplies ? String(localized: "Stop reading replies aloud") : String(localized: "Read replies aloud"),
                                  systemImage: model.speakReplies ? "speaker.slash" : "speaker.wave.2")
                        }
                        if model.speaker.isSpeaking {
                            Button { model.speaker.stop() } label: { Label("Stop speaking", systemImage: "stop.fill") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }.fontWeight(.semibold)
                }
            }
        }
    }

    private var notice: some View {
        Label(!model.isConnected ? String(localized: "Connect to a Flipper first (Device tab)") : String(localized: "Add your API key in Settings"),
              systemImage: "exclamationmark.circle")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.orange)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.orange.opacity(0.12), in: .capsule)
            .padding(.top, 4)
    }

    /// Shown while engagement mode is armed, so the operator always sees the session state.
#if !FLIPPERHERO_STORE
    private struct EngagementBanner: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("ENGAGED").font(.caption.weight(.heavy).monospaced())
                    if !model.engagement.profile.note.isEmpty {
                        Text(model.engagement.profile.note).font(.caption2).lineLimit(1)
                    }
                }
                Spacer()
                Button("Disarm") { model.applyEngagement(.inactive, audit: true) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.danger, in: .rect)
            .padding(.horizontal, 10).padding(.top, 6)
        }
    }
#endif

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable().scaledToFit()
                    .frame(width: 104, height: 104)
                    .clipShape(.rect(cornerRadius: 24, style: .continuous))
                    .shadow(color: Theme.orange.opacity(0.35), radius: 24)
                    .padding(.top, 40)
                VStack(spacing: 6) {
                    Text("Ask FlipperHero").font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Read files, check the device, make changes you approve.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    ForEach(Self.suggestions, id: \.1) { icon, text in
                        Button { Task { await model.send(text) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon).foregroundStyle(Theme.orange).frame(width: 24)
                                Text(text).font(.subheadline).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .background(Theme.card, in: .rect(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
                        }
                        .buttonStyle(.plain)
                        .disabled(!ready)
                        .opacity(ready ? 1 : 0.45)
                    }
                }
                .padding(.horizontal)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(TapGesture().onEnded { focused = false })
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.chat) { entry in
                        EntryView(entry: entry).id(entry.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.isBusy { ThinkingBubble().id("thinking") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .animation(.snappy, value: model.chat.count)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .onChange(of: model.chat.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.isBusy) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if case .denied(let why) = voice.state {
                Text(why).font(.caption).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let attachment, let image = UIImage(data: attachment) {
                HStack {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 8))
                    Text("Photo attached").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { self.attachment = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                }
            }
            composerRow
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .sheet(isPresented: $showCamera) {
            CameraPicker { attachment = $0 }.ignoresSafeArea()
        }
        .onChange(of: voice.transcript) { input = voice.transcript }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button { showCamera = true } label: {
                Image(systemName: "camera.fill").font(.callout)
                    .foregroundStyle(Theme.orange)
                    .frame(width: 38, height: 38)
                    .background(Theme.card, in: .circle)
            }
            .disabled(!ready || model.isBusy)
            TextField("Ask about your Flipper...", text: $input, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Theme.card, in: .rect(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
            Button {
                Task { await voice.toggle() }
            } label: {
                Image(systemName: voice.isListening ? "waveform" : "mic.fill").font(.callout)
                    .foregroundStyle(voice.isListening ? .black : Theme.orange)
                    .frame(width: 38, height: 38)
                    .background(voice.isListening ? Theme.orange : Theme.card, in: .circle)
                    .symbolEffect(.variableColor, isActive: voice.isListening)
            }
            .disabled(!ready || model.isBusy)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(canSend ? .black : .gray)
                    .frame(width: 42, height: 42)
                    .background(canSend ? Theme.orange : Theme.card, in: .circle)
            }
            .disabled(!canSend)
            .sensoryFeedback(.impact(weight: .light), trigger: model.chat.count)
        }
    }

    private func send() {
        guard canSend else { return }
        voice.stop()
        let text = input.isEmpty && attachment != nil ? String(localized: "What is this?") : input
        let images = attachment.map { [$0] } ?? []
        input = ""
        attachment = nil
        Task { await model.send(text, images: images) }
    }
}

// MARK: - Entries

private struct EntryView: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack(alignment: .bottom) {
                Spacer(minLength: 56)
                if let data = entry.image, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 10))
                }
                Text(entry.text)
                    .font(.body).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.orange, in: .rect(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.fill").font(.caption.weight(.bold)).foregroundStyle(.black)
                    .frame(width: 26, height: 26).background(Theme.orange, in: .circle)
                Text(Self.markdown(entry.text))
                    .font(.body)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.card, in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
                    .textSelection(.enabled)
                Spacer(minLength: 24)
            }
        case .tool:
            ToolCard(entry: entry)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Theme.danger)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("- ") ? "\u{2022} " + $0.dropFirst(2) : String($0) }
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct ToolCard: View {
    let entry: ChatEntry
    @State private var expanded = false

    private var tint: Color {
        switch entry.status {
        case .running: Theme.orange
        case .ok: Theme.ok
        case .error, .blocked: Theme.danger
        case .denied: Color.yellow
        }
    }

    private var symbol: String {
        switch entry.tool {
        case "list_directory": "folder"
        case "read_file": "doc.text"
        case "get_device_info": "cpu"
        case "get_power_info": "battery.75"
        case "get_storage_info": "externaldrive"
        case "create_directory": "folder.badge.plus"
        case "write_file": "square.and.pencil"
        case "rename", "move": "arrow.left.arrow.right"
        case "launch_app": "play.rectangle"
        case "delete": "trash"
#if !FLIPPERHERO_STORE
        case "badusb_execute": "keyboard"
        case "rpc_raw": "terminal"
        case "gpio": "cable.connector"
        case "set_engagement_mode": "shield.lefthalf.filled"
        case "generate_engagement_report": "list.clipboard"
#endif
        default: "wrench.and.screwdriver"
        }
    }

    private var statusLabel: String {
        switch entry.status {
        case .running: String(localized: "running")
        case .ok: String(localized: "done")
        case .error: String(localized: "failed")
        case .denied: String(localized: "denied")
        case .blocked: String(localized: "blocked")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !entry.output.isEmpty else { return }
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
                    Text(entry.text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if entry.status == .running {
                        ProgressView().controlSize(.small).tint(Theme.orange)
                    } else {
                        Text(statusLabel).font(.system(.caption2, design: .monospaced).weight(.semibold)).foregroundStyle(tint)
                        if !entry.output.isEmpty {
                            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(Theme.stroke)
                Text(entry.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.card, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3).clipShape(.rect(topLeadingRadius: 12, bottomLeadingRadius: 12))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
        .padding(.leading, 36)
    }
}

private struct ThinkingBubble: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.caption.weight(.bold)).foregroundStyle(.black)
                .frame(width: 26, height: 26).background(Theme.orange, in: .circle)
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(Theme.orange)
                            .frame(width: 7, height: 7)
                            .opacity(0.35 + 0.65 * max(0, sin(t * 4 - Double(i) * 0.7)))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(Theme.card, in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
        }
    }
}
