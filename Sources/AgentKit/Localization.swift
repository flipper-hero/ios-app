import Foundation

/// User-facing text from AgentKit's string catalog (Resources/Localizable.xcstrings).
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
