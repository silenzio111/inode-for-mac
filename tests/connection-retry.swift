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
        alreadyOnline.applyEthernetProbeResult((google: false, baidu: false), interface: "en-test", address: "10.0.0.8")
        precondition(!alreadyOnline.detectedEthernetOnline && !alreadyOnline.internet,
                     "A later failed Ethernet probe must clear a stale connected state")
        alreadyOnline.applyEthernetProbeResult((google: false, baidu: true), interface: "en-test", address: "10.0.0.8")
        precondition(alreadyOnline.detectedEthernetOnline && alreadyOnline.internet,
                     "A subsequent successful probe must restore the connected state")
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
        try "starting\tTechnical engine startup\nnotice\tE0585 control fields 48/49/50\nphase\t正在等待".write(to: progressEvents, atomically: true, encoding: .utf8)
        progress.tick()
        precondition(progress.message == "正在准备校园网认证…", "An incomplete event line must wait for its newline")
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

        let crashed = Connection()
        crashed.retryLimit = 3
        let crashedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-crashed-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: crashedDirectory, withIntermediateDirectories: false)
        try "starting\tHelper started\n".write(to: crashedDirectory.appendingPathComponent("events"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: crashedDirectory.appendingPathComponent("finished").path, contents: Data())
        crashed.useSyntheticSession(crashedDirectory)
        crashed.tick()
        precondition(crashed.retryScheduled && !crashed.busy,
                     "A helper that exits without stopped must end the UI session and schedule retry")

        let neverStarted = Connection()
        neverStarted.authMode = "vendor"
        neverStarted.retryLimit = 3
        let emptyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-empty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: emptyDirectory.appendingPathComponent("events").path, contents: Data())
        neverStarted.useSyntheticSession(emptyDirectory)
        neverStarted.tick()
        precondition(neverStarted.busy && !neverStarted.retryScheduled,
                     "A startup timeout must request helper shutdown before reusing the session")
        neverStarted.expireSyntheticStopDeadline()
        neverStarted.tick()
        precondition(neverStarted.retryScheduled && !neverStarted.busy,
                     "A component startup timeout is an internal failure, not a user cancellation")

        let peapNeverStarted = Connection()
        peapNeverStarted.authMode = "peap"
        peapNeverStarted.retryLimit = 3
        let peapDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-peap-empty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: peapDirectory, withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: peapDirectory.appendingPathComponent("events").path, contents: Data())
        peapNeverStarted.useSyntheticSession(peapDirectory)
        peapNeverStarted.tick()
        peapNeverStarted.expireSyntheticStopDeadline()
        peapNeverStarted.tick()
        precondition(peapNeverStarted.retryScheduled && !peapNeverStarted.busy,
                     "A PEAP startup timeout should also schedule retry after stopping its helper")

        let swapped = Connection()
        swapped.retryLimit = 3
        swapped.adapters = [Adapter(id: "en-old", name: "Old Ethernet", active: true, ip: "10.0.0.8")]
        swapped.selected = "en-old"
        let swappedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("inode-swapped-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: swappedDirectory, withIntermediateDirectories: false)
        let swappedEvents = swappedDirectory.appendingPathComponent("events")
        try "starting\tHelper started\n".write(to: swappedEvents, atomically: true, encoding: .utf8)
        swapped.useSyntheticSession(swappedDirectory)
        swapped.authenticated = true
        swapped.applyAdapterScan([Adapter(id: "en-new", name: "New Ethernet", active: true, ip: "10.0.0.9")])
        precondition(!swapped.authenticated && swapped.selected == "en-new" &&
                     FileManager.default.fileExists(atPath: swappedDirectory.appendingPathComponent("stop").path),
                     "Authentication on a removed adapter must not transfer to another adapter")
        try "starting\tHelper started\nstopped\tOld adapter stopped\n".write(to: swappedEvents, atomically: true, encoding: .utf8)
        swapped.tick()
        precondition(swapped.retryScheduled, "A lost authentication adapter should retry after the old session stops")

        let renewed = Connection()
        renewed.adapters = [Adapter(id: "en-ip", name: "Ethernet", active: true, ip: "10.0.0.8")]
        renewed.selected = "en-ip"
        renewed.useSyntheticInternetResult(address: "10.0.0.8")
        renewed.applyAdapterScan([Adapter(id: "en-ip", name: "Ethernet", active: true, ip: "10.0.0.9")])
        precondition(!renewed.internet && renewed.headline != "已连接",
                     "An IP change must invalidate connectivity measured on the old address")
        print("Ethernet startup, helper exit, timeout, adapter replacement, retry, and cancellation passed")
    }
}
