import SwiftUI
import AppKit
import Combine
import Darwin

struct Adapter: Identifiable, Hashable {
    var id: String
    var name: String
    var active: Bool
    var ip: String
}
func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do {
        try p.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(data: bytes, encoding: .utf8) ?? "")
    } catch { return (-1, error.localizedDescription) }
}
private func runBounded(_ path: String, _ args: [String], timeout: TimeInterval = 3) -> (Int32, String) {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
            return (-1, "")
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: bytes, encoding: .utf8) ?? "")
    } catch { return (-1, "") }
}
private func scanAdapters() -> [Adapter]? {
    let hardware = runBounded("/usr/sbin/networksetup", ["-listallhardwareports"])
    guard hardware.0 == 0 else { return nil }
    var found: [Adapter] = []
    for block in hardware.1.components(separatedBy: "\n\n") {
        let lines = block.components(separatedBy: "\n")
        guard let port = lines.first(where: { $0.hasPrefix("Hardware Port: ") }),
              let dev = lines.first(where: { $0.hasPrefix("Device: ") }) else { continue }
        let name = String(port.dropFirst(15)), id = String(dev.dropFirst(8))
        if name == "Wi-Fi" || name == "AirPort" || name == "Thunderbolt Bridge" || name == "雷雳网桥" || !id.hasPrefix("en") { continue }
        let config = runBounded("/sbin/ifconfig", [id])
        guard config.0 == 0 else { return nil }
        let ip = config.1.components(separatedBy: "\n").compactMap { line -> String? in
            let words = line.split(whereSeparator: { $0.isWhitespace })
            guard words.count > 1, words[0] == "inet", !words[1].hasPrefix("169.254.") else { return nil }
            return String(words[1])
        }.first ?? ""
        found.append(Adapter(id: id, name: name, active: config.1.contains("status: active"), ip: ip))
    }
    return found.sorted { $0.active && !$1.active }
}
private func canReachSite(_ url: String, on interface: String, expectedStatus: ClosedRange<Int>) -> Bool {
    let result = run("/usr/bin/curl", ["-q", "--ipv4", "--interface", "if!\(interface)", "--proxy", "", "--noproxy", "*", "--proto", "=https", "--connect-timeout", "4", "--max-time", "7", "--max-redirs", "0", "--silent", "--output", "/dev/null", "--write-out", "%{http_code}", url])
    let status = Int(result.1.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    return result.0 == 0 && expectedStatus.contains(status)
}
private func checkGoogleAndBaidu(on interface: String, address: String) async -> (google: Bool, baidu: Bool) {
    let google = Task.detached { canReachSite("https://www.google.com/generate_204", on: interface, expectedStatus: 204...204) }
    let baidu = Task.detached { canReachSite("https://www.baidu.com/", on: interface, expectedStatus: 200...299) }
    let direct = Task.detached(priority: .utility) {
        directEthernetHTTPSChecks(interface: interface, address: address)
    }
    let pinned = Task.detached(priority: .utility) { dnsPinnedBaiduHTTPS(on: interface) }
    let curlResult = (await google.value, await baidu.value)
    let directResult = await direct.value
    let pinnedBaidu = await pinned.value
    return (curlResult.0 || directResult.google, curlResult.1 || directResult.baidu || pinnedBaidu)
}
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
}
@MainActor final class Connection: ObservableObject {
    @Published var showLog = false
    @Published var adapters: [Adapter] = []
    @Published var selected = UserDefaults.standard.string(forKey: "adapter") ?? "en8"
    @Published var username = ""
    @Published var password = ""
    @Published var realm = UserDefaults.standard.string(forKey: "realm") ?? "移动"
    @Published var authMode = UserDefaults.standard.string(forKey: "authMode") ?? "vendor"
    @Published var remember = UserDefaults.standard.object(forKey: "remember") as? Bool ?? true
    @Published var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true
    @Published var retryLimit = UserDefaults.standard.object(forKey: "retryLimit") as? Int ?? 3
    @Published var launchAtLogin = LoginItem.isEnabled()
    @Published var showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
    @Published var preferencesMessage = ""
    @Published var serviceGBK = UserDefaults.standard.bool(forKey: "serviceGBK")
    @Published var xorMode = UserDefaults.standard.bool(forKey: "xorMode")
    @Published var busy = false
    @Published var authenticated = false
    @Published var detectedEthernetOnline = false
    @Published var internet = false
    @Published var googleReachable: Bool?
    @Published var baiduReachable: Bool?
    @Published var checkingInternet = false
    @Published var message = "输入校园网账号，开始有线认证。"
    @Published var error = false
    @Published var logs: [String] = []
    private var session: URL?
    private var linesRead = 0
    private var timer: Timer?
    private var lastScan = Date.distantPast
    private var scanInFlight = false
    private var scanCompletions: [() -> Void] = []
    private var launchTime = Date.distantPast
    private var terminated = false
    private var authorizing = false
    private var attemptedInternet = false
    private var startupPending = false
    private var startupProbePending = true
    private var startupIPWaitSince: Date?
    #if INODE_TESTING
    private let automaticEthernetProbeEnabled = false
    #else
    private let automaticEthernetProbeEnabled = ProcessInfo.processInfo.environment["INODE_DISABLE_STARTUP_PROBE"] != "1"
    #endif
    private var ethernetProbeRunning = false
    private var ethernetProbeGeneration = 0
    private var monitorPassiveEthernet = false
    private var detectedEthernetAddress: String?
    private var lastInternetCheck = Date.distantPast
    private var lastInternetAddress: String?
    private var internetProbeGeneration = 0
    private var sessionInterface: String?
    private var failureStopRequested = false
    private var stopDeadline: Date?
    private var restoredPEAPPid: pid_t?
    private var retryAttempt = 0
    @Published private(set) var retryDeadline: Date?
    private var userRequestedStop = false
    private var brokerDirectory: URL?
    var account: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var submittedAccount: String { campusSubmittedAccount(account, realm: realm) }

    var adapter: Adapter? { adapters.first { $0.id == selected } }
    var campusReady: Bool { authenticated || detectedEthernetOnline }
    var hasIP: Bool { campusReady && !(adapter?.ip ?? "").isEmpty }
    var retryScheduled: Bool { retryDeadline != nil }
    var headline: String {
        if internet { return "已连接" }
        if retryScheduled { return "正在自动重试" }
        if error { return "需要处理" }
        if ethernetProbeRunning { return "正在检测有线网络" }
        if authenticated && !hasIP { return "正在等待学校服务器分配 IP" }
        if authenticated && checkingInternet { return "正在检测网络连接" }
        if authenticated { return "认证已通过" }
        if startupPending { return "等待有线网卡" }
        return busy ? "正在连接" : "连接校园网"
    }
    var internetDetail: String {
        if authenticated && !hasIP { return "等待有线 IP 地址" }
        if checkingInternet { return "正在检测网络连接" }
        if !attemptedInternet { return "尚未检测网络连接" }
        return internet ? "网络连接正常" : "网络连接测试未通过"
    }
    init(restartHandoff: RestartHandoff? = nil) {
        retryLimit = min(10, max(0, retryLimit))
        let oldAccount = UserDefaults.standard.string(forKey: "username")
        UserDefaults.standard.removeObject(forKey: "username")
        UserDefaults.standard.synchronize()
        #if !INODE_TESTING
        do {
            if let saved = try CredentialStore.load() {
                username = saved.account
                realm = saved.realm
                password = saved.password
            } else {
                username = oldAccount ?? ""
                if remember && !username.isEmpty {
                    preferencesMessage = "升级后请重新输入密码，连接一次即可保存到本机。"
                }
            }
        } catch {
            username = oldAccount ?? ""
            preferencesMessage = "本机保存的账号密码无法读取，请重新输入并保存。"
            addLog("本机加密凭据读取失败")
        }
        #else
        username = oldAccount ?? ""
        #endif
        refresh()
        userRequestedStop = restartHandoff?.userRequestedStop ?? false
        if let broker = restartHandoff?.brokerDirectory,
           RestartHandoff.isPrivateDirectory(broker, prefix: "inode-broker-") {
            brokerDirectory = broker
            addLog(PrivilegeBroker.isRunning(in: broker) ? "已接管重启前授权的认证组件" : "正在等待重启前授权的认证组件就绪")
        }
        if let previous = restartHandoff?.sessionDirectory,
           RestartHandoff.isPrivateDirectory(previous, prefix: "inode-"),
           FileManager.default.fileExists(atPath: previous.appendingPathComponent("events").path) {
            session = previous
            let savedInterface = try? String(contentsOf: previous.appendingPathComponent("interface"), encoding: .utf8)
            sessionInterface = savedInterface?.trimmingCharacters(in: .whitespacesAndNewlines) ?? selected
            if authMode == "peap",
               let text = try? String(contentsOf: previous.appendingPathComponent("helper-pid"), encoding: .utf8),
               let number = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), number > 1 {
                restoredPEAPPid = number
            }
            busy = true
            authorizing = false
            launchTime = Date()
            startupProbePending = false
            addLog("已接管重启前的有线认证会话")
            tick()
        }
        startupPending = autoConnect && !account.isEmpty && !password.isEmpty &&
            session == nil && !retryScheduled && !userRequestedStop &&
            ProcessInfo.processInfo.environment["INODE_DISABLE_AUTO_CONNECT"] != "1"
        if startupPending && adapter?.active != true { message = "等待上次使用的有线网卡接入…" }
        let poller = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(poller, forMode: .common)
        timer = poller
        if session == nil { probeEthernetIfAvailable() }
    }
    func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        logs.append("\(f.string(from: Date()))  \(s)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
    func refresh(after: (() -> Void)? = nil) {
        if let after { scanCompletions.append(after) }
        guard !scanInFlight else { return }
        scanInFlight = true
        lastScan = Date()
        #if INODE_TESTING
        finishScan(scanAdapters())
        #else
        Task {
            let result = await Task.detached(priority: .utility) { scanAdapters() }.value
            finishScan(result)
        }
        #endif
    }
    private func finishScan(_ result: [Adapter]?) {
        scanInFlight = false
        if let result { applyAdapterScan(result) }
        else { addLog("有线网卡扫描未完成，将在下一轮重试") }
        let completions = scanCompletions
        scanCompletions.removeAll()
        completions.forEach { $0() }
    }
    func applyAdapterScan(_ found: [Adapter]) {
        let previousAddress = adapter?.ip ?? ""
        let activeSessionLinkLost = sessionInterface.map { interface in
            found.first(where: { $0.id == interface })?.active != true
        } ?? false
        adapters = found
        if activeSessionLinkLost { requestSessionStopForFailure("认证所用的网卡已断开，等待网线接入后自动重试。") }
        if !found.contains(where: { $0.id == selected }), let first = found.first { selectAdapter(first.id) }
        if session == nil && !busy && previousAddress.isEmpty && !(adapter?.ip ?? "").isEmpty {
            startupProbePending = true
        }
        if detectedEthernetOnline && (adapter?.active != true || adapter?.ip != detectedEthernetAddress) {
            detectedEthernetOnline = false
            detectedEthernetAddress = nil
            internet = false
            googleReachable = nil
            baiduReachable = nil
            attemptedInternet = false
            startupProbePending = true
            startupPending = autoConnect && !account.isEmpty && !password.isEmpty
            startupIPWaitSince = nil
            message = "有线网络状态已改变，正在重新检查。"
        }
        if authenticated, let lastInternetAddress, adapter?.ip != lastInternetAddress {
            internet = false
            googleReachable = nil
            baiduReachable = nil
            attemptedInternet = false
            lastInternetCheck = .distantPast
            self.lastInternetAddress = nil
        }
        if session == nil { probeEthernetIfAvailable() }
    }
    func loadPassword() {
        guard let saved = try? CredentialStore.load(),
              saved.account == account, saved.realm == realm else { password = ""; return }
        password = saved.password
    }
    func selectAdapter(_ identifier: String) {
        guard selected != identifier else { return }
        cancelEthernetProbe()
        monitorPassiveEthernet = false
        selected = identifier
        UserDefaults.standard.set(identifier, forKey: "adapter")
        if detectedEthernetOnline {
            detectedEthernetOnline = false
            detectedEthernetAddress = nil
            internet = false
            googleReachable = nil
            baiduReachable = nil
            attemptedInternet = false
        }
        startupProbePending = true
        startupIPWaitSince = nil
        if session == nil && !busy { message = "正在检查所选有线网卡…" }
    }
    func tick() {
        reapRestoredPEAPIfNeeded()
        if Date().timeIntervalSince(lastScan) >= 2 { refresh() }
        if startupProbePending && session == nil { probeEthernetIfAvailable() }
        if startupPending && !scanInFlight && !startupProbePending && !ethernetProbeRunning && adapter?.active == true {
            startupPending = false
            addLog("使用上次保存的配置自动连接")
            connect()
        }
        if let retryDeadline, session == nil, Date() >= retryDeadline {
            if adapter?.active == true {
                self.retryDeadline = nil
                retryAttempt += 1
                addLog("第 \(retryAttempt)/\(retryLimit) 次自动重试")
                beginConnection()
            } else {
                self.retryDeadline = Date().addingTimeInterval(2)
                message = "等待网线接入后自动重试…"
            }
        }
        if monitorPassiveEthernet && session == nil && !ethernetProbeRunning && !scanInFlight &&
            !startupProbePending && Date().timeIntervalSince(lastInternetCheck) >= 30,
            let adapter, adapter.active, !adapter.ip.isEmpty { startEthernetProbe(on: adapter) }
        guard let session else { return }
        let text = (try? String(contentsOf: session.appendingPathComponent("events"), encoding: .utf8)) ?? ""
        let completeText = text.lastIndex(of: "\n").map { String(text[...$0]) } ?? ""
        let lines = completeText.split(separator: "\n").map(String.init)
        if lines.count < linesRead { linesRead = 0 }
        if lines.count > linesRead {
            for line in lines.dropFirst(linesRead) {
                let parts = line.components(separatedBy: "\t"); guard parts.count >= 2 else { continue }
                let state = parts[0], detail = parts.dropFirst().joined(separator: "\t")
                addLog(detail)
                if state == "authenticated" { authenticated = true; retryAttempt = 0; error = false; message = detail }
                else if state == "starting" && !error { message = "正在准备校园网认证…" }
                else if state == "phase" && !authenticated && !error { message = detail }
                else if state == "error" || state == "expired" {
                    error = true; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; message = detail
                    if authMode == "vendor" && stopDeadline == nil {
                        stopDeadline = Date().addingTimeInterval(8)
                        FileManager.default.createFile(atPath: session.appendingPathComponent("stop").path,
                                                       contents: Data(), attributes: [.posixPermissions: 0o600])
                    }
                }
                else if state == "stopped" {
                    busy = false; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; terminated = true
                    if !error { message = detail }
                }
            }
            linesRead = lines.count
        }
        let startupTimeout: TimeInterval = authMode == "vendor" ? 60 : 15
        if busy && !authorizing && lines.isEmpty && Date().timeIntervalSince(launchTime) > startupTimeout {
            failSessionStartup("认证组件未启动，请查看日志或重试管理员授权。")
        }
        if busy && !terminated && FileManager.default.fileExists(atPath: session.appendingPathComponent("finished").path) {
            busy = false; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; terminated = true
            if !userRequestedStop && !error {
                error = true; message = "认证组件意外退出，正在准备重试。"; addLog(message)
            }
        }
        if busy && !terminated, let stopDeadline, Date() >= stopDeadline {
            if let brokerDirectory { PrivilegeBroker.stop(in: brokerDirectory); self.brokerDirectory = nil }
            if authMode == "peap" { signalPEAPProcess(in: session, signal: SIGKILL) }
            busy = false; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil
            attemptedInternet = false; terminated = true
            addLog("认证组件未及时结束，已请求后台组件停止")
        }
        if terminated {
            cleanup()
            if !userRequestedStop && retryAttempt < retryLimit {
                retryDeadline = Date().addingTimeInterval(3)
                error = false
                message = "即将自动重试（第 \(retryAttempt + 1)/\(retryLimit) 次）。"
                addLog(message)
            }
            return
        }
        if authenticated && !hasIP { waitForAddress() }
        if authenticated && hasIP && !checkingInternet &&
            (!attemptedInternet || Date().timeIntervalSince(lastInternetCheck) >= 30) { checkInternet() }
    }
    private func reapRestoredPEAPIfNeeded() {
        guard let pid = restoredPEAPPid else { return }
        var status: Int32 = 0
        let observed = Darwin.waitpid(pid, &status, WNOHANG)
        if observed == pid || (observed == -1 && errno == ECHILD && Darwin.kill(pid, 0) == -1 && errno == ESRCH) {
            restoredPEAPPid = nil
            if let session, busy {
                FileManager.default.createFile(atPath: session.appendingPathComponent("finished").path,
                                               contents: Data(), attributes: [.posixPermissions: 0o600])
            }
        }
    }
    private func signalPEAPProcess(in session: URL, signal: Int32) {
        guard let text = try? String(contentsOf: session.appendingPathComponent("helper-pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        var status: Int32 = 0
        let observed = Darwin.waitpid(pid, &status, WNOHANG)
        if observed == 0 { Darwin.kill(pid, signal) }
        else if observed == pid {
            FileManager.default.createFile(atPath: session.appendingPathComponent("finished").path,
                                           contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }
    private func requestSessionStopForFailure(_ reason: String) {
        guard let session, !failureStopRequested else { return }
        failureStopRequested = true
        if authMode == "vendor" { stopDeadline = Date().addingTimeInterval(8) }
        internetProbeGeneration += 1
        FileManager.default.createFile(atPath: session.appendingPathComponent("stop").path,
                                       contents: Data(), attributes: [.posixPermissions: 0o600])
        authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false
        error = true; message = reason; addLog(reason)
    }
    private func failSessionStartup(_ reason: String) {
        guard !failureStopRequested else { return }
        requestSessionStopForFailure(reason)
        if let brokerDirectory { PrivilegeBroker.stop(in: brokerDirectory); self.brokerDirectory = nil }
        if authMode == "peap" { stopDeadline = Date().addingTimeInterval(8) }
        if authMode == "peap", let session { signalPEAPProcess(in: session, signal: SIGTERM) }
    }
    private func waitForAddress() {
        internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false
        message = "正在等待学校服务器分配 IP 地址…"
    }
    private func probeEthernetIfAvailable() {
        guard startupProbePending else { return }
        guard automaticEthernetProbeEnabled else { startupProbePending = false; return }
        guard let adapter, adapter.active, session == nil, !busy else { return }
        if adapter.ip.isEmpty {
            if startupPending {
                if startupIPWaitSince == nil { startupIPWaitSince = Date() }
                if let started = startupIPWaitSince, Date().timeIntervalSince(started) >= 4 {
                    startupProbePending = false
                    startupIPWaitSince = nil
                }
            }
            return
        }
        startupProbePending = false
        startupIPWaitSince = nil
        startEthernetProbe(on: adapter)
    }
    private func startEthernetProbe(on adapter: Adapter) {
        guard !ethernetProbeRunning else { return }
        ethernetProbeGeneration += 1
        let generation = ethernetProbeGeneration
        ethernetProbeRunning = true
        checkingInternet = true
        error = false
        message = "正在通过所选有线网卡检测网络连接…"
        let interface = adapter.id, address = adapter.ip
        Task {
            let result = await checkGoogleAndBaidu(on: interface, address: address)
            guard generation == ethernetProbeGeneration else { return }
            ethernetProbeRunning = false
            checkingInternet = false
            applyEthernetProbeResult(result, interface: interface, address: address)
        }
    }
    func applyEthernetProbeResult(_ result: (google: Bool, baidu: Bool), interface: String, address: String) {
        guard session == nil, !busy else { return }
        guard selected == interface, adapter?.active == true, adapter?.ip == address else {
            startupProbePending = true
            return
        }
        googleReachable = result.google
        baiduReachable = result.baidu
        attemptedInternet = true
        lastInternetCheck = Date()
        if result.google || result.baidu {
            let wasMonitored = monitorPassiveEthernet
            monitorPassiveEthernet = true
            detectedEthernetOnline = true
            detectedEthernetAddress = address
            internet = true
            startupPending = false
            error = false
            message = "选中的有线网卡可正常上网，无需重复认证。"
            addLog(wasMonitored ? "有线网卡网络复查通过" : "启动检测：所选有线网卡可正常上网，跳过重复认证")
        } else {
            let wasOnline = detectedEthernetOnline
            detectedEthernetOnline = false
            detectedEthernetAddress = nil
            internet = false
            if wasOnline && autoConnect && !account.isEmpty && !password.isEmpty && !userRequestedStop {
                startupPending = true
            }
            message = startupPending ? "有线网络尚未连通，准备使用上次配置认证…" : "有线网络尚未连通，请连接校园网。"
            addLog("所选有线网卡网络测试未通过")
        }
    }
    private func cancelEthernetProbe() {
        ethernetProbeGeneration += 1
        ethernetProbeRunning = false
        checkingInternet = false
        startupProbePending = false
        startupIPWaitSince = nil
    }
    func checkInternet() {
        guard let current = session, authenticated, hasIP else { return }
        let testedAddress = adapter?.ip
        guard let testedAddress, !testedAddress.isEmpty else { waitForAddress(); return }
        let interface = selected
        internetProbeGeneration += 1
        let generation = internetProbeGeneration
        checkingInternet = true; attemptedInternet = true
        message = "已取得有线 IP 地址，正在检测网络连通性…"
        Task {
            let result = await checkGoogleAndBaidu(on: interface, address: testedAddress)
            guard generation == internetProbeGeneration else { return }
            guard session == current, authenticated else { checkingInternet = false; return }
            guard hasIP, selected == interface, adapter?.ip == testedAddress else {
                checkingInternet = false; attemptedInternet = false
                if !hasIP { waitForAddress() }
                return
            }
            googleReachable = result.google; baiduReachable = result.baidu
            internet = result.google || result.baidu
            checkingInternet = false
            lastInternetCheck = Date()
            lastInternetAddress = testedAddress
            message = internet ? "网络连接正常。" : "校园网认证已通过，网络连接测试未通过。"
            addLog("所选有线网卡网络测试：\(internetDetail)；认证状态单独判定")
            // The timer will recheck connectivity after the regular interval.
        }
    }
    func manualRefresh() {
        refresh { [weak self] in
            guard let self else { return }
            if self.session == nil, let adapter = self.adapter, adapter.active, !adapter.ip.isEmpty {
                self.startEthernetProbe(on: adapter)
                return
            }
            guard self.authenticated else { return }
            guard self.hasIP else { self.waitForAddress(); return }
            if !self.checkingInternet {
                self.attemptedInternet = false; self.internet = false; self.googleReachable = nil; self.baiduReachable = nil
                self.checkInternet()
            }
        }
    }
    func connect() {
        cancelEthernetProbe()
        monitorPassiveEthernet = false
        internetProbeGeneration += 1
        detectedEthernetOnline = false
        detectedEthernetAddress = nil
        internet = false
        startupPending = false
        retryDeadline = nil
        retryAttempt = 0
        userRequestedStop = false
        beginConnection()
    }
    private func beginConnection() {
        guard !busy else { return }
        guard adapter?.active == true else { error = true; message = "请先插好网线，并选择已接入的有线网卡。"; return }
        let service = realm.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = [selected, submittedAccount, password, service]
        guard !account.isEmpty, !password.isEmpty, service.utf8.count <= 64, values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") && $0.utf8.count <= 240 }) else {
            error = true; message = "请填写有效的账号和密码。"; return
        }
        UserDefaults.standard.set(realm, forKey: "realm")
        UserDefaults.standard.set(selected, forKey: "adapter"); UserDefaults.standard.set(remember, forKey: "remember")
        UserDefaults.standard.set(xorMode, forKey: "xorMode")
        UserDefaults.standard.set(serviceGBK, forKey: "serviceGBK")
        UserDefaults.standard.set(authMode, forKey: "authMode")
        if remember {
            do {
                try CredentialStore.save(SavedCredentials(account: account, realm: realm, password: password))
                preferencesMessage = ""
            } catch {
                preferencesMessage = "账号密码未能保存到本机；本次连接仍可继续。"
                addLog("本机加密凭据保存失败")
            }
        } else {
            do { try CredentialStore.delete() }
            catch { addLog("清除本机加密凭据失败") }
        }
        cleanup()
        sessionInterface = selected
        failureStopRequested = false
        stopDeadline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inode-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let content = "\(selected)\n\(submittedAccount)\n\(password)\n\(xorMode ? 1 : 0)\n\(ProcessInfo.processInfo.processIdentifier)\n\(service)\n\(serviceGBK ? "GBK" : "UTF-8")\n"
            let config = dir.appendingPathComponent("credentials")
            FileManager.default.createFile(atPath: config.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600])
            FileManager.default.createFile(atPath: dir.appendingPathComponent("interface").path,
                                           contents: Data(selected.utf8), attributes: [.posixPermissions: 0o600])
            FileManager.default.createFile(atPath: dir.appendingPathComponent("events").path, contents: Data(), attributes: [.posixPermissions: 0o600])
            session = dir; linesRead = 0; busy = true; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; checkingInternet = false; error = false; terminated = false; authorizing = true; attemptedInternet = false
            let usePEAP = authMode == "peap"
            let reuseBroker = !usePEAP && brokerDirectory.map { PrivilegeBroker.isRunning(in: $0) } == true
            launchTime = Date()
            message = usePEAP ? "正在启动 macOS 有线 PEAP 认证…" :
                (reuseBroker ? "正在复用已授权的认证组件…" : "请在 macOS 弹窗中允许有线认证。")
            addLog("准备启动有线认证组件（\(selected)）")
            addLog(submittedAccount != account ? "移动账号按学校 Mac 教程补全 @cm；密码未改动" : "使用填写的账号格式；密码未改动")
            guard let helper = Bundle.main.url(forResource: "inode-helper", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            if reuseBroker, let brokerDirectory {
                try PrivilegeBroker.enqueue(dir, in: brokerDirectory)
                authorizing = false
                addLog("复用本次运行已授权的认证组件，无需再次请求管理员授权")
                return
            }
            let broker: URL?
            if usePEAP { broker = nil }
            else {
                let created = try PrivilegeBroker.createDirectory()
                try PrivilegeBroker.enqueue(dir, in: created)
                brokerDirectory = created
                broker = created
            }
            Task {
                let result = await Task.detached { () -> (Int32, String) in
                    if usePEAP {
                        let process = Process(); process.executableURL = helper
                        process.arguments = ["--peap-session", dir.path]
                        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                        do {
                            try process.run()
                            guard FileManager.default.createFile(atPath: dir.appendingPathComponent("helper-pid").path,
                                                                 contents: Data(String(process.processIdentifier).utf8),
                                                                 attributes: [.posixPermissions: 0o600]) else {
                                process.terminate(); process.waitUntilExit()
                                return (-1, "")
                            }
                            Task.detached {
                                process.waitUntilExit()
                                FileManager.default.createFile(atPath: dir.appendingPathComponent("finished").path,
                                                               contents: Data(), attributes: [.posixPermissions: 0o600])
                            }
                            return (0, "")
                        } catch { return (-1, "") }
                    }
                    guard let broker else { return (-1, "") }
                    let command = shellQuote(helper.path) + " --broker " + shellQuote(broker.path) +
                        " " + String(ProcessInfo.processInfo.processIdentifier) + " </dev/null >/dev/null 2>&1 &"
                    let script = "do shell script " + appleQuote(command) + " with administrator privileges"
                    return run("/usr/bin/osascript", ["-e", script])
                }.value
                guard session == dir else { return }
                authorizing = false
                NotificationCenter.default.post(name: Notification.Name("inodeAuthorizationFinished"), object: nil)
                if result.0 != 0 {
                    if brokerDirectory == broker { brokerDirectory = nil }
                    busy = false; error = true; message = usePEAP ? "PEAP 认证组件启动失败。" : "管理员授权取消或启动失败。"; addLog(message); cleanup()
                } else {
                    launchTime = Date()
                    message = "正在启动有线认证…"
                    if !usePEAP { addLog("已启动本次运行可复用的授权组件") }
                }
            }
        } catch { busy = false; self.error = true; message = "无法启动认证组件：\(error.localizedDescription)"; cleanup() }
    }
    func disconnect() {
        cancelEthernetProbe()
        monitorPassiveEthernet = false
        internetProbeGeneration += 1
        detectedEthernetOnline = false
        detectedEthernetAddress = nil
        startupPending = false
        retryDeadline = nil
        userRequestedStop = true
        let hadSession = session != nil
        if let session {
            FileManager.default.createFile(atPath: session.appendingPathComponent("stop").path,
                                           contents: Data(), attributes: [.posixPermissions: 0o600])
            if authMode == "vendor" { stopDeadline = Date().addingTimeInterval(8) }
        }
        authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; message = hadSession ? "正在断开有线认证…" : "已取消自动重试。"
        lastInternetAddress = nil
        if session == nil { busy = false }
    }
    func shutdownBroker() {
        if let brokerDirectory { PrivilegeBroker.stop(in: brokerDirectory) }
        brokerDirectory = nil
    }
    var authorizationInProgress: Bool { authorizing }
    func restartHandoff() -> RestartHandoff {
        RestartHandoff(brokerDirectory: brokerDirectory, sessionDirectory: session,
                       userRequestedStop: userRequestedStop)
    }
    private func cleanup() {
        if let session {
            // Do not remove a live session: the helper needs its stop marker.
            if busy { return }
            if terminated || FileManager.default.fileExists(atPath: session.appendingPathComponent("credentials").path) {
                try? FileManager.default.removeItem(at: session)
            }
        }
        session = nil; sessionInterface = nil; failureStopRequested = false; stopDeadline = nil; terminated = false
    }
    #if INODE_TESTING
    func useSyntheticSession(_ directory: URL) {
        session = directory
        sessionInterface = selected
        linesRead = 0
        busy = true
    }
    func useSyntheticInternetResult(address: String) {
        authenticated = true
        internet = true
        attemptedInternet = true
        lastInternetAddress = address
        lastInternetCheck = Date()
    }
    func expireSyntheticStopDeadline() { stopDeadline = .distantPast }
    #endif
    func forgetPassword() {
        do {
            try CredentialStore.delete()
            username = ""; password = ""; remember = false
            UserDefaults.standard.set(false, forKey: "remember")
            preferencesMessage = ""
            addLog("已清除本机保存的账号与密码")
        } catch {
            preferencesMessage = "清除本机账号密码失败：\(error.localizedDescription)"
        }
    }
    func setRemember(_ enabled: Bool) {
        remember = enabled
        UserDefaults.standard.set(enabled, forKey: "remember")
        preferencesMessage = ""
        if enabled {
            if !account.isEmpty && !password.isEmpty {
                do { try CredentialStore.save(SavedCredentials(account: account, realm: realm, password: password)) }
                catch { preferencesMessage = "账号密码未能保存到本机：\(error.localizedDescription)" }
            }
        } else {
            do {
                try CredentialStore.delete()
                startupPending = false
            } catch {
                remember = true
                UserDefaults.standard.set(true, forKey: "remember")
                preferencesMessage = "清除本机账号密码失败：\(error.localizedDescription)"
            }
        }
    }
    func setAutoConnect(_ enabled: Bool) {
        autoConnect = enabled
        UserDefaults.standard.set(enabled, forKey: "autoConnect")
        if !enabled { startupPending = false }
    }
    func setRetryLimit(_ count: Int) {
        retryLimit = min(10, max(0, count))
        UserDefaults.standard.set(retryLimit, forKey: "retryLimit")
        if retryAttempt >= retryLimit && retryScheduled {
            retryDeadline = nil
            message = "已取消自动重试。"
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLogin = enabled
            preferencesMessage = ""
            addLog(enabled ? "已开启登录后启动" : "已关闭登录后启动")
        } catch {
            launchAtLogin = LoginItem.isEnabled()
            preferencesMessage = "无法修改开机自启：\(error.localizedDescription)"
            addLog(preferencesMessage)
        }
    }
    func setShowDockIcon(_ enabled: Bool) {
        showDockIcon = enabled
        UserDefaults.standard.set(enabled, forKey: "showDockIcon")
        NSApp.setActivationPolicy(enabled ? .regular : .accessory)
    }
}

let green = Color(red: 0.08, green: 0.55, blue: 0.36)
private enum WindowLayout {
    static let compactHeight: CGFloat = 490
    static let editorHeight: CGFloat = 780
    static let editorMinimumHeight: CGFloat = 770
}
struct ContentView: View {
    @ObservedObject var model: Connection
    var onWindowClosed: () -> Void
    var onRestart: () -> Void
    private var compact: Bool { model.busy || model.retryScheduled || model.campusReady }
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 20 : 28) {
                HStack(spacing: 10) {
                    Image(systemName: "network").font(.system(size: 24, weight: .semibold)).foregroundStyle(green)
                    VStack(alignment: .leading, spacing: 3) { Text("iNode for Mac").font(.headline); Text("西南财经大学").font(.caption).foregroundStyle(.secondary) }
                }.padding(.bottom, compact ? 8 : 18)
                Text("连接步骤").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                step(1, "有线链路", model.adapter?.active == true ? "网线已接入" : "等待接入", model.adapter?.active == true)
                step(2, "校园网认证", model.authenticated ? "已通过" : (model.detectedEthernetOnline ? "有线已联网" : (model.retryScheduled ? "即将重试" : (model.busy ? "认证中" : "等待认证"))), model.campusReady)
                step(3, "网络地址", model.hasIP ? "已获取" : (model.campusReady ? "等待获取" : "等待认证"), model.hasIP)
                Divider()
                Text("启动与显示").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("开机自启", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Toggle("启动后自动连接", isOn: Binding(get: { model.autoConnect }, set: { model.setAutoConnect($0) }))
                    Toggle("在 Dock 显示图标", isOn: Binding(get: { model.showDockIcon }, set: { model.setShowDockIcon($0) }))
                    Picker("失败后重试", selection: Binding(get: { model.retryLimit }, set: { model.setRetryLimit($0) })) {
                        Text("不重试").tag(0)
                        ForEach(1...10, id: \.self) { count in Text("\(count) 次").tag(count) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.checkbox).font(.caption)
                if !model.preferencesMessage.isEmpty {
                    Text(model.preferencesMessage).font(.caption2).foregroundStyle(.orange)
                }
                if model.autoConnect && !model.remember {
                    Text("自动连接需要先保存账号密码并连接一次。").font(.caption2).foregroundStyle(.secondary)
                }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 225).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 22) {
                    Image(systemName: model.internet ? "checkmark.circle.fill" : (model.error ? "exclamationmark.circle.fill" : "cable.connector"))
                        .font(.system(size: 52, weight: .light)).foregroundStyle(model.error ? .orange : green)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.headline)
                            .font(.system(size: 30, weight: .bold))
                        Text(model.message).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.busy && !model.authenticated { ProgressView().controlSize(.small) }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(green.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                if !model.busy && !model.retryScheduled && !model.detectedEthernetOnline {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack { Text("校园网账号").font(.headline); Spacer(); Text("宿舍有线 · 移动").font(.caption).foregroundStyle(.secondary) }
                        HStack(spacing: 14) {
                            field("学号 / 完整账号") { TextField("请输入学号", text: $model.username).onSubmit { model.loadPassword() } }
                            field("密码") { SecureField("校园网密码", text: $model.password) }
                        }
                        HStack {
                            Toggle("本机加密保存账号与密码", isOn: Binding(get: { model.remember }, set: { model.setRemember($0) })).toggleStyle(.checkbox)
                            Spacer()
                            Button("清除已保存账号密码") { model.forgetPassword() }.buttonStyle(.link)
                        }.font(.caption)
                        HStack {
                            Picker("认证方式", selection: $model.authMode) {
                                Text("普通认证（iNode）").tag("vendor")
                                Text("高级认证（PEAP）").tag("peap")
                            }.frame(width: 280)
                            Spacer()
                        }.font(.caption)
                        Text(model.authMode == "peap" ? "按 Windows 教程提供的 PEAP 备选模式，尚未验证此网口是否适用。" : "连接选项与 Linux 项目一致，由 iNode 认证组件处理。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("账号格式", selection: $model.realm) {
                                Text("移动（@cm）").tag("移动")
                                Text("按填写账号").tag("")
                                if !model.realm.isEmpty && model.realm != "移动" { Text("其他账号（原样）").tag(model.realm) }
                            }.frame(width: 255)
                            Spacer()
                        }.font(.caption)
                        Text("移动账号按学校 Mac 教程使用 @cm；已填写完整账号时保持原样。")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("查看认证账号") {
                            HStack {
                                Text("认证账号：\(model.submittedAccount.isEmpty ? "尚未填写" : model.submittedAccount)")
                            }.padding(.top, 8)
                        }.font(.caption)
                    }.padding(22).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("连接信息").font(.headline)
                    HStack {
                        Label("有线网卡", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Picker("有线网卡", selection: Binding(get: { model.selected }, set: { model.selectAdapter($0) })) {
                            ForEach(model.adapters) { a in Text("\(a.name) · \(a.id)\(a.active ? "（已接入）" : "")").tag(a.id) }
                        }.labelsHidden().disabled(model.busy || model.retryScheduled)
                    }
                    Divider()
                    info("IPv4 地址", "location", model.hasIP ? (model.adapter?.ip ?? "") : (model.campusReady ? "尚未取得有效地址" : "认证后检查地址"))
                    Divider()
                    info("认证状态", "checkmark.shield", model.authenticated ? "校园网认证已通过" : (model.detectedEthernetOnline ? "有线网卡已联网，无需重复认证" : "尚未通过认证"))
                    Divider()
                    info("网络连通性", "globe", model.internetDetail)
                }.padding(22).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
                if model.busy || model.retryScheduled {
                    actionBar.padding(.top, 8)
                }
                    }.padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 18)
                }
                if !model.busy && !model.retryScheduled {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        if !model.campusReady {
                            Label("建议在认证完成后再启用代理软件", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        actionBar
                    }.padding(.horizontal, 30).padding(.top, 14).padding(.bottom, 20)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 920, minHeight: compact ? WindowLayout.compactHeight : WindowLayout.editorMinimumHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .background(HideOnClose(onClose: onWindowClosed).frame(width: 0, height: 0))
            .sheet(isPresented: $model.showLog) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("连接日志").font(.title2.bold()); Spacer(); Button("关闭") { model.showLog = false } }
                    Text("记录认证阶段、错误及已脱敏的通知，不记录账号、密码或原始报文。").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(model.logs.isEmpty ? "暂无认证日志。" : model.logs.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.logs.joined(separator: "\n"), forType: .string) }
                }.padding(24).frame(width: 690, height: 420)
            }
    }
    var actionBar: some View {
        HStack {
                    Button { model.showLog = true } label: { Label("连接日志", systemImage: "list.bullet.rectangle") }
                    Button { onRestart() } label: { Label("重启软件", systemImage: "arrow.clockwise.circle") }
                    Spacer()
                    Button { model.manualRefresh() } label: { Label("刷新状态", systemImage: "arrow.clockwise") }.disabled(model.checkingInternet)
                    if model.detectedEthernetOnline {
                        Label("有线网络已连接", systemImage: "checkmark.circle.fill").foregroundStyle(green)
                    } else if model.busy || model.retryScheduled {
                        Button(role: .destructive) { model.disconnect() } label: { Label(model.retryScheduled ? "取消重试" : "断开连接", systemImage: "xmark") }
                    } else {
                        Button { model.connect() } label: { Label("连接校园网", systemImage: "bolt.fill") }.buttonStyle(.borderedProminent).tint(green)
                    }
        }.controlSize(.large)
    }
    func step(_ n: Int, _ title: String, _ detail: String, _ done: Bool) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(done ? "✓" : "\(n)").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30).foregroundStyle(done ? .white : .secondary).background(done ? green : Color.primary.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 15, weight: .semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
    func info(_ title: String, _ icon: String, _ value: String) -> some View {
        HStack { Label(title, systemImage: icon).foregroundStyle(.secondary).frame(width: 110, alignment: .leading); Text(value).textSelection(.enabled); Spacer() }.font(.system(size: 13))
    }
    func field<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.caption).foregroundStyle(.secondary); content().textFieldStyle(.roundedBorder).controlSize(.large) }
    }
}
@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: Connection?
    private var mainWindow: NSPanel?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var windowSizeObservation: AnyCancellable?
    private var mainWindowHiddenByUser = false
    private var restartInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let connection = Connection(restartHandoff: RestartHandoff(arguments: ProcessInfo.processInfo.arguments))
        model = connection
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "iNode for Mac")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        let state = NSMenuItem(title: connection.headline, action: nil, keyEquivalent: "")
        state.isEnabled = false
        statusMenuItem = state
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打开主界面", action: #selector(openMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重启 iNode for Mac", action: #selector(restart), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 iNode for Mac", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil { entry.target = self }
        item.menu = menu
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(restoreAfterAuthorization),
                                               name: Notification.Name("inodeAuthorizationFinished"), object: nil)

        if !ProcessInfo.processInfo.arguments.contains("--launched-at-login") { openMainWindow() }
        windowSizeObservation = connection.$busy
            .combineLatest(connection.$authenticated, connection.$detectedEthernetOnline, connection.$retryDeadline)
            .map { busy, authenticated, detectedOnline, retryDeadline in busy || authenticated || detectedOnline || retryDeadline != nil }
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] compact in self?.resizeMainWindow(compact: compact) }
    }

    func menuWillOpen(_ menu: NSMenu) { statusMenuItem?.title = model?.headline ?? "iNode for Mac" }

    @objc private func openMainWindow() {
        guard let model else { return }
        if mainWindow == nil {
            let compact = model.busy || model.retryScheduled || model.campusReady
            let height = compact ? WindowLayout.compactHeight : WindowLayout.editorHeight
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: height),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            window.title = "iNode for Mac"
            window.hidesOnDeactivate = false
            window.level = .normal
            let minimumContentHeight = compact ? WindowLayout.compactHeight : WindowLayout.editorMinimumHeight
            window.minSize = NSSize(width: 920, height: frameHeight(for: minimumContentHeight, in: window))
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(model: model, onWindowClosed: { [weak self] in
                self?.mainWindowHiddenByUser = true
                NSApp.setActivationPolicy(.accessory)
            }, onRestart: { [weak self] in self?.restart() }))
            window.center()
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindowHiddenByUser = false
        NSApp.setActivationPolicy(model.showDockIcon ? .regular : .accessory)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func frameHeight(for contentHeight: CGFloat, in window: NSWindow) -> CGFloat {
        window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 980, height: contentHeight)).height
    }

    private func resizeMainWindow(compact: Bool) {
        guard let window = mainWindow else { return }
        let contentHeight = compact ? WindowLayout.compactHeight : WindowLayout.editorHeight
        let minimumContentHeight = compact ? WindowLayout.compactHeight : WindowLayout.editorMinimumHeight
        let targetHeight = frameHeight(for: contentHeight, in: window)
        let minimumSize = NSSize(width: 920, height: frameHeight(for: minimumContentHeight, in: window))
        if compact { window.minSize = minimumSize }
        guard abs(window.frame.height - targetHeight) > 1 else {
            window.minSize = minimumSize
            return
        }
        var frame = window.frame
        frame.origin.y += frame.height - targetHeight
        frame.size.height = targetHeight
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
        if !compact { window.minSize = minimumSize }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func restart() {
        guard !restartInProgress, let model else { return }
        guard !model.authorizationInProgress else {
            showRestartError("请先完成或取消当前管理员授权，再重启软件。")
            return
        }
        guard let executable = Bundle.main.executableURL else {
            showRestartError("无法定位应用程序，请重新安装后再试。")
            return
        }
        restartInProgress = true
        let handoff = model.restartHandoff()
        UserDefaults.standard.synchronize()
        DispatchQueue.main.async { [weak self] in
            let failure = RestartProcess.replace(executable: executable, handoff: handoff)
            self?.restartInProgress = false
            self?.showRestartError("无法重启软件：\(String(cString: strerror(failure)))")
        }
    }

    private func showRestartError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重启未完成"
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func restoreAfterAuthorization() {
        guard let window = mainWindow, !mainWindowHiddenByUser, !window.isMiniaturized, !window.isVisible else { return }
        NSApp.unhideWithoutActivation()
        window.orderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.disconnect()
        model?.shutdownBroker()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }
}

#if !INODE_TESTING
@main struct InodeMac: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    var body: some Scene { Settings { EmptyView() } }
}
#endif
