import Darwin
import Foundation

struct RestartHandoff {
    let brokerDirectory: URL?
    let sessionDirectory: URL?
    let userRequestedStop: Bool

    init(brokerDirectory: URL?, sessionDirectory: URL?, userRequestedStop: Bool = false) {
        self.brokerDirectory = brokerDirectory
        self.sessionDirectory = sessionDirectory
        self.userRequestedStop = userRequestedStop
    }

    init?(arguments: [String]) {
        guard arguments.count == 5, arguments[1] == "--inode-restart",
              arguments[4] == "0" || arguments[4] == "1" else { return nil }
        brokerDirectory = arguments[2] == "-" ? nil : URL(fileURLWithPath: arguments[2])
        sessionDirectory = arguments[3] == "-" ? nil : URL(fileURLWithPath: arguments[3])
        userRequestedStop = arguments[4] == "1"
    }

    var arguments: [String] {
        ["--inode-restart", brokerDirectory?.path ?? "-", sessionDirectory?.path ?? "-", userRequestedStop ? "1" : "0"]
    }

    static func isPrivateDirectory(_ directory: URL, prefix: String) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        guard directory.lastPathComponent.hasPrefix(prefix),
              resolved.deletingLastPathComponent() == temporary else { return false }
        var details = stat()
        guard lstat(directory.path, &details) == 0 else { return false }
        return details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
            details.st_uid == getuid() && details.st_mode & 0o077 == 0
    }
}

enum RestartProcess {
    // execv keeps this process's PID, which the authorized broker and session monitor.
    // On success it never returns; on failure the existing app keeps running.
    static func replace(executable: URL, handoff: RestartHandoff) -> Int32 {
        let values = [executable.path] + handoff.arguments
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { if let pointer = $0 { free(pointer) } }
            return ENOMEM
        }
        pointers.append(nil)
        defer { pointers.forEach { if let pointer = $0 { free(pointer) } } }
        return executable.path.withCString { path in
            pointers.withUnsafeMutableBufferPointer { buffer in
                Darwin.execv(path, buffer.baseAddress!)
                return errno
            }
        }
    }
}
