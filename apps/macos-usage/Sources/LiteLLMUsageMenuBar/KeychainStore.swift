import Foundation
import Security

struct KeychainStore: Sendable {
    private let service = "com.litellm.usage-menubar"
    private let credentialsAccount = "ui-credentials"

    func readCredentials() async throws -> (username: String, password: String)? {
        let data = try await Task.detached(priority: .userInitiated) {
            try self.read(account: self.credentialsAccount)
        }.value
        guard let data else { return nil }
        return try JSONDecoder().decode(StoredCredentials.self, from: data).tuple
    }

    func saveCredentials(username: String, password: String) throws {
        let data = try JSONEncoder().encode(StoredCredentials(username: username, password: password))
        try save(data, account: credentialsAccount)
    }

    private func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status) }
        guard let data = result as? Data else { throw KeychainError(errSecDecode) }
        return data
    }

    private func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError(addStatus)
        }
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus != errSecSuccess {
            throw KeychainError(updateStatus)
        }
    }
}

private struct StoredCredentials: Codable {
    let username: String
    let password: String

    var tuple: (username: String, password: String) {
        (username, password)
    }
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    init(_ status: OSStatus) { self.status = status }

    var errorDescription: String? {
        if status == errSecUserCanceled { return "저장된 로그인 정보 접근이 취소되었습니다" }
        if status == errSecInteractionNotAllowed { return "macOS에서 Keychain 접근을 허용해주세요" }
        if status == errSecAuthFailed { return "저장된 로그인 정보에 접근할 수 없습니다. 설정에서 다시 저장하세요" }
        return "Keychain 처리에 실패했습니다 (\(status))"
    }
}
