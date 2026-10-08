import SwiftUI

enum Theme {
    static let orange = Color(red: 1.0, green: 0.51, blue: 0.0)
    static let background = Color(red: 0.04, green: 0.04, blue: 0.045)
    static let card = Color(white: 0.10)
    static let stroke = Color.white.opacity(0.09)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let danger = Color(red: 1.0, green: 0.32, blue: 0.30)

    static var glow: some View {
        LinearGradient(colors: [orange.opacity(0.14), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45))
            .ignoresSafeArea()
    }
}
