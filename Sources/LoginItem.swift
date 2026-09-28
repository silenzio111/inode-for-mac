import Foundation

enum LoginItem {
    static let label = "local.swufe.inode-mac.login"

    static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(home: home).path)
    }

    static func contents(appPath: String) throws -> Data {
        let properties: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath, "--args", "--launched-at-login"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        return try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    }

    static func setEnabled(_ enabled: Bool, appPath: String = Bundle.main.bundlePath,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let file = fileURL(home: home)
        if enabled {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents(appPath: appPath).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
