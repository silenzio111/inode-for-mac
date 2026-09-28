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

        let alreadyOnline = Connection()
        alreadyOnline.adapters = [Adapter(id: "en-test", name: "Synthetic Ethernet", active: true, ip: "10.0.0.8")]
        alreadyOnline.selected = "en-test"
        alreadyOnline.applyEthernetProbeResult((google: true, baidu: false), interface: "en-other", address: "10.0.0.8")
        precondition(!alreadyOnline.campusReady, "Another interface must not mark this Ethernet link online")
        alreadyOnline.applyEthernetProbeResult((google: true, baidu: false), interface: "en-test", address: "10.0.0.7")
        precondition(!alreadyOnline.campusReady, "A stale address must not mark the link online")
        alreadyOnline.applyEthernetProbeResult((google: true, baidu: false), interface: "en-test", address: "10.0.0.8")
        precondition(alreadyOnline.detectedEthernetOnline && alreadyOnline.hasIP && alreadyOnline.internet)
        precondition(!alreadyOnline.authenticated, "A website probe must not claim an engine authentication result")
        precondition(alreadyOnline.headline == "已连接")
        alreadyOnline.selectAdapter("en-other")
        precondition(!alreadyOnline.detectedEthernetOnline && !alreadyOnline.internet,
                     "Changing the selected adapter must clear the old Ethernet result")

        let previousSession = FileManager.default.temporaryDirectory.appendingPathComponent("inode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: previousSession, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: previousSession.appendingPathComponent("events").path,
                                       contents: Data("starting\tRestored session\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        let resumed = Connection(restartHandoff: RestartHandoff(brokerDirectory: nil, sessionDirectory: previousSession))
        precondition(resumed.busy && resumed.logs.contains(where: { $0.contains("Restored session") }),
                     "Restart must attach to the existing session without starting another one")
        try FileManager.default.removeItem(at: previousSession)

        let stoppedBeforeRestart = FileManager.default.temporaryDirectory.appendingPathComponent("inode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stoppedBeforeRestart, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: stoppedBeforeRestart.appendingPathComponent("events").path,
                                       contents: Data("stopped\tUser requested stop\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        let resumedAfterStop = Connection(restartHandoff: RestartHandoff(brokerDirectory: nil,
                                                                         sessionDirectory: stoppedBeforeRestart,
                                                                         userRequestedStop: true))
        precondition(!resumedAfterStop.retryScheduled && !resumedAfterStop.busy,
                     "Restart must preserve an intentional disconnect")
        try? FileManager.default.removeItem(at: stoppedBeforeRestart)

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
        print("Ethernet-only startup result, authentication-gated IP status, progress, retry, and cancellation passed")
    }
}
