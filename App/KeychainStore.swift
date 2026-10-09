import Foundation
import Security

enum KeychainStore {
    /// Scoped to the bundle id, so forks with their own id never share entries.
    private static let service = Bundle.main.bundleIdentifier ?? "FlipperHero"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored value; an empty value deletes it. Returns the Security framework status.
    @discardableResult
    static func write(_ value: String, account: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        guard update == errSecItemNotFound else { return update }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Readable after the first unlock so a relaunch while the phone is locked does not lose the key.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    #if DEBUG
    /// Prints whether the Keychain works on this device. Never prints stored values.
    static func selfTest() {
        let wrote = write("probe-value", account: "selftest")
        let readBack = read("selftest") == "probe-value"
        write("", account: "selftest")
        let existing = read("openrouter")
        print("[Keychain] write status=\(wrote) readBack=\(readBack) openrouterKeyPresent=\(existing != nil) length=\(existing?.count ?? 0)")
    }
    #endif
}
