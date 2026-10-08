import XCTest

/// Every string catalog in the repository must be complete in every supported language,
/// with the same placeholders as the English source. A new UI text without translations fails here.
final class LocalizationTests: XCTestCase {
    static let languages = ["de", "fr", "es", "pt-BR", "it", "ru", "uk", "pl", "tr", "ar", "hi", "zh-Hans", "ja", "ko"]
    private static let placeholder = try! NSRegularExpression(pattern: #"%(?:\d\$)?(?:@|lld|llu|lf|d|u|%)|\$\{[a-zA-Z]+\}"#)

    private var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func catalogs() throws -> [URL] {
        let skip = [".build", "DerivedData", ".git", "FlipperHero.xcodeproj"]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        var found: [URL] = []
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.pathExtension == "xcstrings" { found.append(url) }
        }
        return found
    }

    private static func placeholders(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return placeholder.matches(in: text, range: range).map {
            String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"^%\d\$"#, with: "%", options: .regularExpression)
        }.sorted()
    }

    /// Plain text or the variation set used for Siri phrases.
    private static func values(_ localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return [value] }
        if let set = localization["stringSet"] as? [String: Any], let values = set["values"] as? [String] { return values }
        return []
    }

    func testCatalogsAreCompleteInEveryLanguage() throws {
        let files = try catalogs()
        XCTAssertGreaterThanOrEqual(files.count, 6, "catalogs were not found")
        var checked = 0
        for file in files {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let strings = json["strings"] as! [String: [String: Any]]
            let name = file.path.replacingOccurrences(of: root.path + "/", with: "")
            for (key, entry) in strings where !key.trimmingCharacters(in: .whitespaces).isEmpty {
                if entry["extractionState"] as? String == "stale" || entry["shouldTranslate"] as? Bool == false { continue }
                let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
                checked += 1
                let english = (localizations["en"].map(Self.values)?.first) ?? key
                for language in Self.languages {
                    guard let localization = localizations[language], let value = Self.values(localization).first,
                          !value.isEmpty else {
                        XCTFail("\(name): '\(key)' has no \(language) translation")
                        continue
                    }
                    if !file.lastPathComponent.hasPrefix("AppShortcuts") {
                        XCTAssertEqual(Self.placeholders(value), Self.placeholders(english),
                                       "\(name): placeholders differ in \(language) for '\(key)'")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 300, "only \(checked) strings were checked")
    }
}
