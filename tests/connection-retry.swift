import Foundation

@main struct ConnectionRetryTest {
    @MainActor static func main() throws {
        let model = Connection()
        model.retryLimit = 3
        model.adapters = [Adapter(id: "en-test", name: "Synthetic Ethernet", active: true, ip: "10.0.0.2")]
        model.selected = "en-test"
        precondition(!model.hasIP, "An address before authentication is not a completed network step")
        model.authenticated = true
        precondition(model.hasIP)
        model.authenticated = false

        let progress = Connection()
        let progressDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-progress-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: progressDirectory, withIntermediateDirectories: false)
        let progressEvents = progressDirectory.appendingPathComponent("events")
        try "starting\tTechnical engine startup\nnotice\tE0585 control fields 48/49/50\n".write(to: progressEvents, atomically: true, encoding: .utf8)
        progress.useSyntheticSession(progressDirectory)
        progress.tick()
        precondition(progress.message == "正在准备校园网认证…", "Technical notices must stay in the log")
        try "starting\tTechnical engine startup\nnotice\tE0585 control fields 48/49/50\nphase\t正在等待校园网认证结果…\n".write(to: progressEvents, atomically: true, encoding: .utf8)
        progress.tick()
        precondition(progress.message == "正在等待校园网认证结果…", "User-facing phases should update the banner")
        try FileManager.default.removeItem(at: progressDirectory)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-retry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try "error\tSynthetic failure\nstopped\tSynthetic session ended\n".write(to: directory.appendingPathComponent("events"), atomically: true, encoding: .utf8)
        model.useSyntheticSession(directory)
        model.tick()
        precondition(model.retryScheduled, "Unexpected authentication failure should schedule a retry")
        precondition(!model.busy)
        model.disconnect()
        precondition(!model.retryScheduled, "User cancellation must cancel retry")

        let stopped = Connection()
        stopped.retryLimit = 3
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("inode-retry-stop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try "stopped\tSynthetic user stop\n".write(to: second.appendingPathComponent("events"), atomically: true, encoding: .utf8)
        stopped.useSyntheticSession(second)
        stopped.disconnect()
        stopped.tick()
        precondition(!stopped.retryScheduled, "User disconnect must never start a retry")

        let disabled = Connection()
        disabled.retryLimit = 0
        let third = FileManager.default.temporaryDirectory.appendingPathComponent("inode-retry-disabled-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: false)
        try "error\tSynthetic failure\nstopped\tSynthetic session ended\n".write(to: third.appendingPathComponent("events"), atomically: true, encoding: .utf8)
        disabled.useSyntheticSession(third)
        disabled.tick()
        precondition(!disabled.retryScheduled, "Zero retry limit must disable automatic retry")
        print("Authentication-gated IP status, readable progress, bounded retry, and cancellation passed")
    }
}
