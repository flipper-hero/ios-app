import SwiftUI
import FlipperKit

struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var showRename = false
    @State private var renaming = ""
    @State private var confirmRestart = false
    @State private var confirmUpdate = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if model.isConnected { infoSection } else { scanSection }
            }
            .themedList()
            .brandedNavigation("Flipper")
            .confirmationDialog("Restart the Flipper?", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button("Restart") { Task { try? await model.restartFlipper() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Whatever runs on the Flipper stops. The app reconnects on its own.")
            }
            .confirmationDialog(model.firmware?.updateAvailable == false ? String(localized: "Reinstall firmware?") : String(localized: "Install firmware update?"),
                                isPresented: $confirmUpdate, titleVisibility: .visible) {
                Button(model.firmware?.updateAvailable == false ? String(localized: "Download and reinstall") : String(localized: "Download and install")) {
                    _ = try? model.startFirmwareUpdate()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(updateIntro + String(localized: "About 12 MB go over Bluetooth, which takes 15 to 25 minutes. Keep the phone close and the app open; the battery needs 30% or a charger. The Flipper restarts and finishes on its own."))
            }
            .alert("Rename Flipper", isPresented: $showRename) {
                TextField("Name", text: $renaming).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await model.rename(to: renaming) } }.disabled(renaming.isEmpty)
            } message: {
                Text("At most \(FlipperName.maxLength) characters: letters, digits, hyphen, underscore. It takes effect after the Flipper restarts.")
            }
            // The Flipper keeps at most 8 characters; trim as you type instead of failing on save.
            .onChange(of: renaming) { _, value in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter(allowed.contains))
                    .prefix(FlipperName.maxLength))
                if cleaned != value { renaming = cleaned }
            }
            .task { if !model.isConnected { model.startScan() } }
            .onDisappear { model.stopScan() }
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            switch model.connection {
            case .idle, .scanning:
                Label(bluetoothText, systemImage: "dot.radiowaves.left.and.right")
            case .connecting(let name):
                VStack(alignment: .leading, spacing: 4) {
                    HStack { ProgressView(); Text("Connecting to \(name)...") }
                    if model.isPairingNewDevice {
                        Text("First time with this Flipper: confirm the same PIN on the phone and on the device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            case .connected(let name):
                DeviceCard(name: model.deviceInfo["hardware_name"] ?? name)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var bluetoothText: String {
        switch model.bluetooth {
        case .ready:
            model.autoConnectActive
                ? String(localized: "Looking for \(model.lastDeviceName ?? "Flipper")...")
                : String(localized: "Searching for Flippers...")
        case .poweredOff: String(localized: "Bluetooth is off")
        case .unauthorized: String(localized: "Bluetooth permission denied. Enable it in iOS Settings.")
        case .unsupported: String(localized: "Bluetooth is not supported")
        case .unknown: String(localized: "Starting Bluetooth...")
        }
    }

    private var scanSection: some View {
        Section("Nearby") {
            if model.devices.isEmpty {
                Text("No Flipper found yet. Turn Bluetooth on at the Flipper (Settings > Bluetooth) and keep it unlocked and close.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                Button {
                    Task { await model.connect(device) }
                } label: {
                    HStack {
                        Text(device.name)
                        if !model.isKnown(device) {
                            Text("new").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.orange.opacity(0.25), in: .capsule)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var infoSection: some View {
        if let error = model.renameError {
            Section {
                Label("Rename failed: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        if let error = model.statusError {
            Section {
                Label("Could not read the status: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        Section("Device") {
            Button { renaming = model.deviceInfo["hardware_name"] ?? ""; showRename = true } label: {
                HStack {
                    Text("Name").foregroundStyle(.primary)
                    Spacer()
                    Text(model.deviceInfo["hardware_name"] ?? "-").foregroundStyle(.secondary)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("renameButton")
            if let firmware = model.firmware {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Firmware", value: firmware.summary)
                    Text(firmware.distribution.notes).font(.caption2).foregroundStyle(.secondary)
                    if let latest = firmware.latestRelease, !model.firmwareUpdate.isBusy {
                        if firmware.updateAvailable == false {
                            HStack {
                                Label("Up to date", systemImage: "checkmark.seal.fill")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.ok)
                                Spacer()
                                Button("Reinstall") { confirmUpdate = true }
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .buttonStyle(.borderless)
                            }
                            .padding(.top, 2)
                        } else {
                            Button(firmware.updateAvailable == nil ? String(localized: "Install release \(latest)") : String(localized: "Install \(latest)")) {
                                confirmUpdate = true
                            }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                            .padding(.top, 2)
                        }
                    }
                }
            } else {
                row("Firmware", [model.deviceInfo["firmware_origin_fork"], model.deviceInfo["firmware_version"]].compactMap { $0 }.joined(separator: " "))
            }
            row("Commit", model.deviceInfo["firmware_commit"])
        }
        if let profile = model.profile, !profile.isEmpty {
            Section("Known to the agent") {
                LabeledContent("Installed apps", value: "\(profile.apps.count)")
                ForEach(profile.folders.filter { $0.fileCount > 0 }, id: \.path) { folder in
                    LabeledContent(FlipperPath.lastComponent(folder.path), value: "\(folder.fileCount)")
                }
                LabeledContent("Updated", value: profile.updated.formatted(date: .omitted, time: .shortened))
            }
        }
        if model.firmwareUpdate.state != .idle {
            Section("Firmware update") {
                UpdateProgressRow(controller: model.firmwareUpdate)
            }
        }
        if model.nameChangePending {
            Section {
                HStack {
                    Label("The new name appears after a restart.", systemImage: "arrow.clockwise.circle")
                        .font(.footnote)
                    Spacer()
                    Button("Restart now") { confirmRestart = true }.font(.footnote.weight(.semibold))
                }
            }
        }
        Section {
            HStack(spacing: 10) {
                ActionTile(title: "Refresh", symbol: "arrow.clockwise") { Task { await model.refreshStatus() } }
                ActionTile(title: "Rescan", symbol: "doc.viewfinder") { Task { await model.rescanDevice() } }
                ActionTile(title: "Restart", symbol: "power") { confirmRestart = true }
                ActionTile(title: "Disconnect", symbol: "xmark.circle", tint: Theme.danger) {
                    Task { await model.disconnect() }
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
        }
    }

    private var updateIntro: String {
        switch model.firmware?.updateAvailable {
        case false?: String(localized: "Your Flipper already runs \(model.firmware?.installedVersion ?? "this release"). This flashes the same release again, which can repair a broken install.") + " "
        case nil: String(localized: "Your Flipper runs a development build. This installs the newest published release instead.") + " "
        default: ""
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        LabeledContent(title, value: (value?.isEmpty ?? true) ? "-" : value!)
    }
}

/// Name, firmware, battery and SD card at a glance.
private struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(.title, design: .rounded, weight: .bold))
                Spacer()
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
            }
            Text(firmwareLine).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.top, -10)
            HStack(spacing: 16) {
                Meter(symbol: charging ? "battery.100.bolt" : "battery.75", title: "Battery",
                      value: batteryLevel.map { Double($0) / 100 },
                      caption: model.batterySummary ?? "-")
                Meter(symbol: "sdcard", title: "SD card", value: storageUsed, caption: storageCaption)
            }
        }
        .padding(.vertical, 6)
    }

    private var firmwareLine: String {
        [model.deviceInfo["firmware_origin_fork"], model.deviceInfo["firmware_version"]]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    private var batteryLevel: Int? {
        (model.power["charge_level"] ?? model.power["charge.level"]).flatMap(Int.init)
    }
    private var charging: Bool {
        (model.power["charge_state"] ?? model.power["charge.state"]) == "charging"
    }
    private var storageUsed: Double? {
        guard let s = model.storage, s.totalSpace > 0 else { return nil }
        return Double(s.totalSpace - s.freeSpace) / Double(s.totalSpace)
    }
    private var storageCaption: String {
        guard let s = model.storage else { return "-" }
        return String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(s.freeSpace), countStyle: .file)) free")
    }
}

private struct Meter: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: Double?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(Theme.orange)
            ProgressView(value: value ?? 0).tint(Theme.orange)
            Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActionTile: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = Theme.orange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.borderless)
    }
}

private struct UpdateProgressRow: View {
    let controller: FirmwareUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.statusText).font(.footnote)
            switch controller.state {
            case .running(_, _, let progress):
                ProgressView(value: progress).tint(Theme.orange)
                Button("Cancel update", role: .destructive) { controller.cancel() }.font(.footnote)
            case .waitingForRestart:
                ProgressView().tint(Theme.orange)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}
