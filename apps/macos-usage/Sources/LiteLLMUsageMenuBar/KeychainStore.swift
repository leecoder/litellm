import Foundation
import Security

struct KeychainStore: Sendable {
    private let service = "com.litellm.usage-menubar"
    private let credentialsAccount = "ui-credentials"
    private let itemNotFoundExitStatus: Int32 = 44

    func readCredentials() throws -> (username: String, password: String)? {
        guard let value = try read(account: credentialsAccount) else { return nil }
        return try JSONDecoder().decode(StoredCredentials.self, from: Data(value.utf8)).tuple
    }

    func saveCredentials(username: String, password: String) throws {
        let value = try JSONEncoder().encode(StoredCredentials(username: username, password: password))
        try save(String(data: value, encoding: .utf8) ?? "", account: credentialsAccount)
    }

    private func read(account: String) throws -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == itemNotFoundExitStatus { return nil }
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(errSecAuthFailed)
        }
        return value.trimmingCharacters(in: .newlines)
    }

    private func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
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
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            return "저장된 로그인 정보에 접근할 수 없습니다. 설정에서 다시 저장하세요"
        }
        return "Keychain 처리에 실패했습니다 (\(status))"
    }
}
