import Foundation

@main struct LoginItemTest {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("inode-login-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = "/Applications/iNode for Mac.app"
        try LoginItem.setEnabled(true, appPath: app, home: home)
        precondition(LoginItem.isEnabled(home: home))
        let file = LoginItem.fileURL(home: home)
        let data = try Data(contentsOf: file)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        precondition(plist["Label"] as? String == LoginItem.label)
        precondition(plist["ProgramArguments"] as? [String] ==
                     ["/usr/bin/open", "-a", app, "--args", "--launched-at-login"])
        precondition(plist["RunAtLoad"] as? Bool == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition(attributes[.posixPermissions] as? Int == 0o600)
        try LoginItem.setEnabled(false, home: home)
        precondition(!LoginItem.isEnabled(home: home))
        print("Login item registration and removal passed")
    }
}
