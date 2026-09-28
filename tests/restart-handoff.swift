import Darwin
import Foundation

@main struct RestartHandoffTest {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--first" {
            let marker = URL(fileURLWithPath: "/tmp/inode-broker-pid-\(getpid())")
            let handoff = RestartHandoff(brokerDirectory: marker, sessionDirectory: nil, userRequestedStop: true)
            let failure = RestartProcess.replace(executable: URL(fileURLWithPath: arguments[0]), handoff: handoff)
            fatalError("execv failed: \(failure)")
        }
        if let handoff = RestartHandoff(arguments: arguments) {
            precondition(handoff.brokerDirectory?.lastPathComponent == "inode-broker-pid-\(getpid())",
                         "Restart must keep the same PID as the authorized broker's parent")
            precondition(handoff.sessionDirectory == nil && handoff.userRequestedStop)
            print("Process replacement kept its PID and restored the broker handoff")
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-broker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        precondition(RestartHandoff.isPrivateDirectory(directory, prefix: "inode-broker-"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        precondition(!RestartHandoff.isPrivateDirectory(directory, prefix: "inode-broker-"),
                     "Restart must not trust a shared control directory")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        process.arguments = ["--first"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "The restarted process must exit successfully")
        precondition(text.contains("Process replacement kept its PID"))
        print(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
