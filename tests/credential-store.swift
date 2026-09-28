import Foundation

@main struct CredentialStoreTest {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("inode-credentials-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = CredentialStore.directory(home: home)
        let credentials = SavedCredentials(account: "synthetic-account", realm: "移动", password: "synthetic-password")

        let empty = try CredentialStore.load(from: directory)
        precondition(empty == nil)
        try CredentialStore.save(credentials, to: directory)
        let loaded = try CredentialStore.load(from: directory)
        precondition(loaded == credentials)

        let key = directory.appendingPathComponent("credential-key.bin")
        let file = directory.appendingPathComponent("credentials.enc")
        let ciphertext = try Data(contentsOf: file)
        precondition(!ciphertext.contains(Data(credentials.account.utf8)))
        precondition(!ciphertext.contains(Data(credentials.password.utf8)))
        for path in [key.path, file.path] {
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            precondition(mode == 0o600)
        }
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        precondition(directoryMode == 0o700)

        var modified = ciphertext
        modified[modified.index(before: modified.endIndex)] ^= 1
        try modified.write(to: file, options: .atomic)
        do {
            _ = try CredentialStore.load(from: directory)
            preconditionFailure("Modified ciphertext must fail authentication")
        } catch {}

        try CredentialStore.save(credentials, to: directory)
        let restored = try CredentialStore.load(from: directory)
        precondition(restored == credentials)
        try CredentialStore.delete(from: directory)
        let removed = try CredentialStore.load(from: directory)
        precondition(removed == nil)
        precondition(!FileManager.default.fileExists(atPath: key.path))
        print("Local encrypted credentials: round trip, permissions, tamper detection, and deletion passed")
    }
}
