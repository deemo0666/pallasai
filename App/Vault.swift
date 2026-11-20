import Foundation
import Security

enum Vault {
    #if os(macOS)
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "dsh-local.mac",
         kSecAttrAccount as String: account]
    }
    #else
    private static let service = "dsh-local"
    /// Where items were kept before the rename; moved over once, on first use.
    private static let formerService = "dsh-go-local"
    /// Read by the engine when an 自动化任务 runs with the phone locked. The rest stay readable only while unlocked.
    private static let lockedAccounts: Set<String> = [DeepSeekAccount.key]

    private static func accessible(_ account: String) -> CFString {
        lockedAccounts.contains(account) ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    private static let migrated: Void = {
        // Items saved before tasks could run on a locked phone. Fails quietly while locked; the next launch tries again.
        for account in lockedAccounts {
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemUpdate(item as CFDictionary, [kSecAttrAccessible as String: accessible(account)] as CFDictionary)
        }
        let old: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: formerService,
                                  kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true, kSecReturnData as String: true]
        var found: CFTypeRef?
        guard SecItemCopyMatching(old as CFDictionary, &found) == errSecSuccess, let items = found as? [[String: Any]] else { return }
        var moved = true
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data else { continue }
            var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecAttrAccount as String: account, kSecValueData as String: data,
                                      kSecAttrAccessible as String: accessible(account)]
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess && status != errSecDuplicateItem { moved = false }
            add.removeAll()
        }
        // Only drop the old items once every one of them is safely under the new name.
        if moved { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: formerService] as CFDictionary) }
    }()

    private static func query(_ account: String) -> [String: Any] {
        _ = migrated
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    #endif

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static func contains(_ account: String) throws -> Bool {
        let status = SecItemCopyMatching(query(account) as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw HostError(String(localized: "无法读取钥匙串（\(status)）。")) }
        return true
    }

    static func read(_ account: String) throws -> String {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8)
        else { throw HostError(String(localized: "无法读取钥匙串（\(status)）。")) }
        return key
    }

    static func save(_ value: String, account: String) throws {
        var lookup = query(account)
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(lookup as CFDictionary)
            if status == errSecItemNotFound { return }
        } else {
            #if os(macOS)
            let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            #else
            let update: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: accessible(account)]
            #endif
            let changed = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
            if changed == errSecItemNotFound {
                lookup.merge(update) { _, new in new }
                status = SecItemAdd(lookup as CFDictionary, nil)
            } else { status = changed }
        }
        guard status == errSecSuccess else { throw HostError(String(localized: "无法更新钥匙串（\(status)）。")) }
    }
}
