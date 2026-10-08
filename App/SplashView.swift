import SwiftUI

/// Short launch animation: the logo lands with an orange glow, radio waves ripple out,
/// a light sweep passes over it, then the wordmark settles and everything fades into the app.
/// With Reduce Motion it is a plain cross-fade.
struct SplashView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var logoIn = false
    @State private var wavesOut = false
    @State private var sweep = false
    @State private var titleIn = false
    @State private var leaving = false

    private let logoSize: CGFloat = 148

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            RadialGradient(colors: [Theme.orange.opacity(logoIn ? 0.30 : 0), .clear],
                           center: .center, startRadius: 0, endRadius: logoIn ? 280 : 40)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.9), value: logoIn)

            if !reduceMotion {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(Theme.orange.opacity(wavesOut ? 0 : 0.5), lineWidth: 2)
                        .frame(width: logoSize, height: logoSize)
                        .scaleEffect(wavesOut ? 2.4 + CGFloat(index) * 0.45 : 0.9)
                        .animation(.easeOut(duration: 1.15).delay(0.22 + Double(index) * 0.16), value: wavesOut)
                }
            }

            VStack(spacing: 24) {
                logo
                Text("FlipperHero")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .tracking(titleIn ? 0.5 : 6)
                    .foregroundStyle(.white)
                    .opacity(titleIn ? 1 : 0)
                    .offset(y: titleIn ? 0 : 14)
            }
        }
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving && !reduceMotion ? 1.06 : 1)
        .sensoryFeedback(.impact(weight: .light), trigger: logoIn)
        .task { await run() }
        .accessibilityHidden(true)
    }

    private var logo: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: logoSize, height: logoSize)
            .overlay {
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: logoSize * 0.45)
                    .rotationEffect(.degrees(18))
                    .offset(x: sweep ? logoSize : -logoSize)
                    .blendMode(.plusLighter)
            }
            .clipShape(.rect(cornerRadius: 34, style: .continuous))
            .shadow(color: Theme.orange.opacity(logoIn ? 0.55 : 0), radius: 32)
            .scaleEffect(logoIn || reduceMotion ? 1 : 0.55)
            .opacity(logoIn ? 1 : 0)
            .blur(radius: logoIn || reduceMotion ? 0 : 12)
    }

    private func run() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { logoIn = true; titleIn = true }
            try? await Task.sleep(for: .milliseconds(650))
        } else {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { logoIn = true }
            wavesOut = true
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeOut(duration: 0.5)) { titleIn = true }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeInOut(duration: 0.75)) { sweep = true }
            try? await Task.sleep(for: .milliseconds(900))
        }
        withAnimation(.easeIn(duration: 0.35)) { leaving = true }
        try? await Task.sleep(for: .milliseconds(360))
        onFinish()
    }
}
