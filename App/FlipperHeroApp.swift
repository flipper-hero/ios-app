import SwiftUI
import FlipperKit

@main
struct FlipperHeroApp: App {
    @State private var model = AppModel.shared
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("-noSplash")

    init() {
        FlipperLog.sink = { AppLog.debug($0) }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if showSplash {
                    SplashView { showSplash = false }
                        .zIndex(1)
                }
            }
            .environment(model)
            .preferredColorScheme(.dark)
            .tint(Theme.orange)
            .task { launch() }
            .sheet(item: Binding(get: { model.pendingApproval }, set: { _ in })) { pending in
                ApprovalSheet(pending: pending)
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .tint(Theme.orange)
                    .interactiveDismissDisabled()
            }
        }
    }

    /// Debug builds understand a few environment variables for screenshots and hardware tests:
    /// FH_DEMO=1 (sample data, no Flipper needed), FH_DEMO_APPROVAL=1, FH_DEMO_YOLO=1,
    /// FH_DEMO_ACTIVITY=1 (with FH_DEMO, starts a sample Live Activity), FH_TAB=0..4 (start tab),
    /// FH_KEYCHAIN_SELFTEST=1.
    private func launch() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["FH_DEMO"] == "1" {
            model.loadDemo(withApproval: env["FH_DEMO_APPROVAL"] == "1")
        } else {
            model.start()
        }
        if env["FH_DEMO_YOLO"] == "1" { model.yolo = true }
        if env["FH_KEYCHAIN_SELFTEST"] == "1" { KeychainStore.selfTest() }
        #else
        model.start()
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            DeviceView().tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }.tag(0)
            RemoteView().tabItem { Label("Remote", systemImage: "dpad") }.tag(1)
            FilesView().tabItem { Label("Files", systemImage: "folder") }.tag(2)
            ChatView().tabItem { Label("Agent", systemImage: "bubble.left.and.text.bubble.right") }.tag(3)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
    }
}
