import SwiftUI

/// The navigation bar every tab shares: logo, wordmark and live status, instead of large titles
/// that push the content down. The tab bar already says which screen this is.
struct BrandHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 9) {
            Image("Logo")
                .resizable().scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(.rect(cornerRadius: 7, style: .continuous))
                .shadow(color: Theme.orange.opacity(0.4), radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("FlipperHero").font(.system(.headline, design: .rounded, weight: .bold))
                    if model.yolo {
                        Text("YOLO").font(.system(.caption2, design: .rounded, weight: .heavy))
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.danger, in: .capsule)
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusLine).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brandHeader")
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: Theme.ok
        case .connecting: Theme.orange
        default: .gray
        }
    }

    private var statusLine: String {
        switch model.connection {
        case .connected:
            let name = model.deviceInfo["hardware_name"] ?? model.deviceDisplayName
            if let battery = model.batterySummary { return "\(name) · \(battery)" }
            return name
        case .connecting(let name): return String(localized: "connecting to \(name)")
        case .scanning: return String(localized: "searching")
        default: return String(localized: "not connected")
        }
    }
}

extension View {
    /// Inline bar with the brand header; `title` is still used for back buttons and accessibility.
    func brandedNavigation(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { BrandHeader() } }
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// Lists on the app's dark background, starting right below the bar.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
            .contentMargins(.top, 6, for: .scrollContent)
            .listSectionSpacing(.compact)
    }
}
