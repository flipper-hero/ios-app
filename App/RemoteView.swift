import SwiftUI
import CoreGraphics
import FlipperKit
import AgentKit

/// Live mirror of the Flipper's display with the device's own buttons.
struct RemoteView: View {
    @Environment(AppModel.self) private var model
    @State private var frame: FlipperScreenFrame?
    @State private var error: String?
    @State private var pressCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if model.isConnected || model.isDemo {
                    VStack(spacing: 14) {
                        // The device's display and buttons do not mirror in right-to-left languages.
                        ScreenMirror(frame: frame ?? (model.isDemo ? DemoScreen.frame : nil))
                            .padding(.horizontal)
                            .environment(\.layoutDirection, .leftToRight)
                        HStack(spacing: 6) {
                            Circle().fill(frame != nil || model.isDemo ? Theme.danger : Color.gray).frame(width: 7, height: 7)
                            Text(frame != nil || model.isDemo ? String(localized: "LIVE") : String(localized: "WAITING FOR SCREEN"))
                                .font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.secondary)
                        }
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(Theme.danger)
                        }
                        Spacer(minLength: 8)
                        ControlPad { key, long in press(key, long: long) }
                            .environment(\.layoutDirection, .leftToRight)
                        Text("Tap for a short press, hold for a long press. Hold Back to leave an app.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                } else {
                    ContentUnavailableView("Not connected", systemImage: "rectangle.on.rectangle.slash",
                                           description: Text("Connect to a Flipper in the Device tab."))
                }
            }
            .brandedNavigation("Remote")
            .sensoryFeedback(.impact(weight: .light), trigger: pressCount)
            .task(id: model.isConnected) { await stream() }
        }
    }

    private func stream() async {
        guard let client = model.client else { return }
        let frames = await client.screenFrames()
        do {
            try await client.acquireScreenStream()
        } catch {
            self.error = String(localized: "Could not start the screen stream: \(String(describing: error))")
            return
        }
        var count = 0
        for await next in frames {
            frame = next
            error = nil
            count += 1
            if count == 1 || count % 50 == 0 { AppLog.debug("screen frames received: \(count)") }
        }
        await client.releaseScreenStream()
    }

    private func press(_ key: FlipperKey, long: Bool) {
        pressCount += 1
        guard let client = model.client else { return }
        Task {
            let started = ContinuousClock.now
            do {
                try await client.press(key, long: long)
                AppLog.debug("press \(key.rawValue) long=\(long) took \(ContinuousClock.now - started)")
            } catch {
                AppLog.error("press \(key.rawValue) failed: \(error)")
                self.error = "\(error)"
            }
        }
    }
}

/// The 128x64 display, scaled with hard pixel edges inside a dark bezel.
private struct ScreenMirror: View {
    let frame: FlipperScreenFrame?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.08))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
            Group {
                if let frame, let image = ScreenRenderer.cgImage(frame, scale: 1) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                } else {
                    Rectangle().fill(Color(red: 1, green: 0.51, blue: 0).opacity(0.85))
                        .overlay(ProgressView().tint(.black))
                }
            }
            .aspectRatio(2, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
            .padding(14)
        }
        .aspectRatio(2.12, contentMode: .fit)
        .shadow(color: Theme.orange.opacity(0.25), radius: 24)
        .accessibilityLabel("Flipper screen")
    }
}

/// Direction pad with OK in the middle and Back beside it, laid out like the device.
private struct ControlPad: View {
    let onPress: (FlipperKey, Bool) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 22) {
            ZStack {
                Circle().fill(Theme.card).overlay(Circle().stroke(Theme.stroke)).frame(width: 236, height: 236)
                key(.up, "chevron.up", size: 68).offset(y: -76)
                key(.down, "chevron.down", size: 68).offset(y: 76)
                key(.left, "chevron.left", size: 68).offset(x: -76)
                key(.right, "chevron.right", size: 68).offset(x: 76)
                key(.ok, nil, size: 84, filled: true)
            }
            key(.back, "arrow.uturn.backward", size: 68)
                .padding(.bottom, 4)
        }
    }

    private func key(_ key: FlipperKey, _ symbol: String?, size: CGFloat = 58, filled: Bool = false) -> some View {
        PadButton(symbol: symbol, label: key.rawValue.uppercased(), size: size, filled: filled) { long in
            onPress(key, long)
        }
        .accessibilityLabel(key.rawValue)
    }
}

private struct PadButton: View {
    let symbol: String?
    let label: String
    let size: CGFloat
    let filled: Bool
    let action: (Bool) -> Void
    /// When the finger went down; one gesture decides between short and long on release.
    /// (A tap gesture plus a long-press gesture on one view swallow each other's touches.)
    @State private var downAt: Date?
    private static let longPress: TimeInterval = 0.45

    var body: some View {
        ZStack {
            Circle().fill(filled ? Theme.orange : Color(white: 0.16))
            if let symbol {
                Image(systemName: symbol).font(.title3.weight(.bold))
                    .foregroundStyle(filled ? .black : Theme.orange)
            } else {
                Text(label).font(.system(.callout, design: .rounded, weight: .heavy)).foregroundStyle(.black)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(downAt != nil ? 0.9 : 1)
        .animation(.snappy(duration: 0.15), value: downAt != nil)
        .contentShape(.circle)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if downAt == nil { downAt = .now } }
                .onEnded { _ in
                    let held = downAt.map { Date.now.timeIntervalSince($0) } ?? 0
                    downAt = nil
                    action(held >= Self.longPress)
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action(false) }
    }
}

/// A rendered 128x64 frame for demo mode and screenshots, so the Remote tab has something to show.
enum DemoScreen {
    static let frame: FlipperScreenFrame = {
        let width = FlipperScreenFrame.width, height = FlipperScreenFrame.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(gray: 1, alpha: 1)
            // Status bar line and a simple menu, drawn as blocks so no fonts are involved.
            context.fill(CGRect(x: 0, y: 52, width: width, height: 1))
            for (row, length) in [(40, 74), (28, 58), (16, 66)] {
                context.fill(CGRect(x: 18, y: row, width: length, height: 7))
            }
            context.fill(CGRect(x: 6, y: 41, width: 6, height: 5))
            context.fill(CGRect(x: 4, y: 55, width: 22, height: 6))
            context.fill(CGRect(x: 108, y: 55, width: 16, height: 6))
            return true
        }
        var buffer = [UInt8](repeating: 0, count: width * height / 8)
        if drawn {
            for y in 0..<height {
                for x in 0..<width where gray[y * width + x] > 127 {
                    buffer[(y / 8) * width + x] |= 1 << UInt8(y % 8)
                }
            }
        }
        return FlipperScreenFrame(buffer: Data(buffer))
    }()
}
