import Foundation
import Security
import SlateSyncDomain

public actor KeychainCredentialStore {
    public static let service = "com.slatesync.app.provider-key"

    public init() {}

    public func value(providerID: String) throws -> String? {
        var query = baseQuery(providerID: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return value
    }

    public func setValue(_ value: String?, providerID: String) throws {
        let query = baseQuery(providerID: providerID)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(status)
            }
            return
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus)
        }
    }

    private func baseQuery(providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
        ]
    }

    private func keychainError(_ status: OSStatus) -> SlateSyncError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 操作失败"
        return SlateSyncError(code: "KEYCHAIN", message: detail)
    }
}
