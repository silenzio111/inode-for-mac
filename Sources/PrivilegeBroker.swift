import Darwin
import Foundation

enum PrivilegeBroker {
    static func createDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func enqueue(_ session: URL, in directory: URL) throws {
        let file = directory.appendingPathComponent("request")
        let temporary = directory.appendingPathComponent(".request-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path,
                                             contents: Data((session.path + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { try FileManager.default.moveItem(at: temporary, to: file) }
        catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func isRunning(in directory: URL) -> Bool {
        guard let data = try? String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8),
              let pid = Int32(data.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    static func stop(in directory: URL) {
        let file = directory.appendingPathComponent("quit")
        FileManager.default.createFile(atPath: file.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
    }
}
