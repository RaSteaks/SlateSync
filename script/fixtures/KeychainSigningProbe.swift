import Foundation
import LocalAuthentication
import Security

// Disposable process fixture: every invocation opens only the explicit test
// keychain, and never prints a credential. It is not an application entrypoint.
let mode = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
let service = CommandLine.arguments[3]
var keychain: SecKeychain?
guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { exit(2) }
// Secret reads must succeed without any UI; status uses the same non-interactive
// context as production to verify that attributes do not prompt either.
if mode != "status" { SecKeychainSetUserInteractionAllowed(false) }
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: "random-regression-account",
]
let status: OSStatus
switch mode {
case "create":
    query[kSecUseKeychain as String] = keychain
    query[kSecValueData as String] = Data("isolated-regression-secret".utf8)
    status = SecItemAdd(query as CFDictionary, nil)
case "status":
    query[kSecMatchSearchList as String] = [keychain]
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &result)
case "read":
    query[kSecMatchSearchList as String] = [keychain]
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess && result as? Data != Data("isolated-regression-secret".utf8) { exit(3) }
default: exit(4)
}
print(status)
