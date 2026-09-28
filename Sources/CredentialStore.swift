import CryptoKit
import Foundation

struct SavedCredentials: Codable, Equatable {
    let account: String
    let realm: String
    let password: String
}

enum CredentialStore {
    private static let associatedData = Data("local.swufe.inode-mac.credentials.v1".utf8)

    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/iNode for Mac", isDirectory: true)
    }

    private static func keyURL(in directory: URL) -> URL { directory.appendingPathComponent("credential-key.bin") }
    private static func dataURL(in directory: URL) -> URL { directory.appendingPathComponent("credentials.enc") }

    static func load(from directory: URL = directory()) throws -> SavedCredentials? {
        let file = dataURL(in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let keyData = try Data(contentsOf: keyURL(in: directory))
        guard keyData.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: associatedData)
        return try JSONDecoder().decode(SavedCredentials.self, from: plain)
    }

    static func save(_ credentials: SavedCredentials, to directory: URL = directory()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let keyFile = keyURL(in: directory)
        let keyData: Data
        if manager.fileExists(atPath: keyFile.path) {
            keyData = try Data(contentsOf: keyFile)
            guard keyData.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            let newKey = SymmetricKey(size: .bits256)
            keyData = newKey.withUnsafeBytes { Data($0) }
            try keyData.write(to: keyFile, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        }

        let plain = try JSONEncoder().encode(credentials)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: keyData), authenticating: associatedData)
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        let file = dataURL(in: directory)
        try combined.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func delete(from directory: URL = directory()) throws {
        let manager = FileManager.default
        for file in [dataURL(in: directory), keyURL(in: directory)] where manager.fileExists(atPath: file.path) {
            try manager.removeItem(at: file)
        }
    }
}
