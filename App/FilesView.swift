import SwiftUI
import FlipperKit

struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.isConnected {
                    DirectoryView(path: "/ext")
                } else {
                    ContentUnavailableView("Not connected", systemImage: "folder.badge.questionmark",
                                           description: Text("Connect to a Flipper in the Device tab."))
                }
            }
            .navigationDestination(for: String.self) { DirectoryView(path: $0) }
            .brandedNavigation("Files")
        }
    }
}

private struct DirectoryView: View {
    @Environment(AppModel.self) private var model
    let path: String
    @State private var entries: [FlipperDirEntry] = []
    @State private var error: String?
    @State private var loading = true
    @State private var preview: FilePreview?

    var body: some View {
        List {
            Section { header }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            Section {
                ForEach(entries, id: \.name) { entry in
                    let full = FlipperPath.join(path, entry.name)
                    if entry.isDirectory {
                        NavigationLink(value: full) {
                            Label { Text(entry.name) } icon: {
                                Image(systemName: Self.folderIcon(entry.name)).foregroundStyle(Theme.orange)
                            }
                        }
                    } else {
                        Button {
                            Task { await open(full, size: entry.size) }
                        } label: {
                            HStack {
                                Label { Text(entry.name).lineLimit(1) } icon: {
                                    Image(systemName: Self.fileIcon(entry.name)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                if !loading && entries.isEmpty && error == nil { Text("Empty").foregroundStyle(.secondary) }
            }
        }
        .themedList()
        .overlay { if loading && entries.isEmpty { ProgressView() } }
        .navigationTitle(FlipperPath.lastComponent(path))
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $preview) { p in
            NavigationStack {
                ScrollView { Text(p.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding() }
                    .navigationTitle(FlipperPath.lastComponent(p.path))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var isRoot: Bool { path == "/ext" }

    /// Where we are, how much is here and, at the top level, how full the SD card is.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isRoot ? "sdcard.fill" : Self.folderIcon(FlipperPath.lastComponent(path)))
                    .font(.title2).foregroundStyle(Theme.orange).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isRoot ? String(localized: "SD card") : FlipperPath.lastComponent(path))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if !loading { counts }
            }
            if isRoot, let storage = model.storage, storage.totalSpace > 0 {
                let used = Double(storage.totalSpace - storage.freeSpace) / Double(storage.totalSpace)
                ProgressView(value: used).tint(Theme.orange)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(storage.freeSpace), countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: Int64(storage.totalSpace), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Icon and number instead of "3 files": no plural rules to get wrong in any language.
    private var counts: some View {
        let folders = entries.filter(\.isDirectory).count
        let files = entries.count - folders
        return VStack(alignment: .trailing, spacing: 2) {
            if folders > 0 { Label("\(folders)", systemImage: "folder") }
            if files > 0 { Label("\(files)", systemImage: "doc") }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    #if DEBUG
    /// Sample SD card for demo mode and screenshots.
    private static func demoEntries(_ path: String) -> [FlipperDirEntry] {
        guard path == "/ext" else { return [] }
        let folders = ["apps", "badusb", "dolphin", "ibutton", "infrared", "lfrfid", "nfc", "subghz", "update"]
        return folders.map { FlipperDirEntry(name: $0, isDirectory: true, size: 0) }
            + [FlipperDirEntry(name: "favorites.txt", isDirectory: false, size: 214)]
    }
    #endif

    private static func folderIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "subghz": "antenna.radiowaves.left.and.right"
        case "nfc": "wave.3.right"
        case "lfrfid": "sensor.tag.radiowaves.forward"
        case "infrared": "av.remote"
        case "ibutton": "key"
        case "badusb", "badkb": "keyboard"
        case "apps", "apps_data": "square.grid.2x2"
        case "update": "arrow.down.circle"
        case "dolphin": "pawprint"
        case "music_player": "music.note"
        default: "folder.fill"
        }
    }

    private static func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "sub": "antenna.radiowaves.left.and.right"
        case "nfc": "wave.3.right"
        case "rfid": "sensor.tag.radiowaves.forward"
        case "ir": "av.remote"
        case "ibtn": "key"
        case "txt", "md": "doc.text"
        case "fap": "app"
        case "png", "bmx", "bm": "photo"
        case "fmf", "wav": "music.note"
        default: "doc"
        }
    }

    private func load() async {
        guard let client = model.client else {
            #if DEBUG
            if model.isDemo { entries = Self.demoEntries(path) }
            #endif
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            entries = try await client.list(path: path)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func open(_ full: String, size: UInt32) async {
        guard let client = model.client else { return }
        guard size <= 32 * 1024 else {
            preview = FilePreview(path: full, text: String(localized: "File is \(size) bytes. Only files up to 32 KB are shown here."))
            return
        }
        do {
            let data = try await client.read(path: full, maxBytes: 32 * 1024)
            let text = (data.contains(0) ? nil : String(data: data, encoding: .utf8)) ?? String(localized: "Binary file, \(data.count) bytes.")
            preview = FilePreview(path: full, text: text)
        } catch {
            preview = FilePreview(path: full, text: "\(error)")
        }
    }
}

private struct FilePreview: Identifiable {
    let id = UUID()
    let path: String
    let text: String
}
