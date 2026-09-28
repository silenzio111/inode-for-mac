import SwiftUI
import AppKit
import Combine

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
private func canReachSite(_ url: String) -> Bool {
    let result = run("/usr/bin/curl", ["--ipv4", "--noproxy", "*", "--connect-timeout", "4", "--max-time", "7", "--max-redirs", "0", "--silent", "--output", "/dev/null", "--write-out", "%{http_code}", url])
    let status = Int(result.1.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    return result.0 == 0 && (200...299).contains(status)
}
private func checkGoogleAndBaidu() -> (google: Bool, baidu: Bool) {
    (canReachSite("https://www.google.com/generate_204"), canReachSite("https://www.baidu.com/"))
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
    private var launchTime = Date.distantPast
    private var terminated = false
    private var authorizing = false
    private var attemptedInternet = false
    private var startupPending = false
    private var retryAttempt = 0
    @Published private(set) var retryDeadline: Date?
    private var userRequestedStop = false
    private var brokerDirectory: URL?
    var account: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var submittedAccount: String { campusSubmittedAccount(account, realm: realm) }

    var adapter: Adapter? { adapters.first { $0.id == selected } }
    var hasIP: Bool { authenticated && !(adapter?.ip ?? "").isEmpty }
    var retryScheduled: Bool { retryDeadline != nil }
    var headline: String {
        if internet { return "已连接" }
        if retryScheduled { return "正在自动重试" }
        if error { return "需要处理" }
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
    init() {
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
        startupPending = autoConnect && !account.isEmpty && !password.isEmpty &&
            ProcessInfo.processInfo.environment["INODE_DISABLE_AUTO_CONNECT"] != "1"
        if startupPending && adapter?.active != true { message = "等待上次使用的有线网卡接入…" }
        let poller = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(poller, forMode: .common)
        timer = poller
    }
    func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        logs.append("\(f.string(from: Date()))  \(s)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
    func refresh() {
        let output = run("/usr/sbin/networksetup", ["-listallhardwareports"]).1
        var found: [Adapter] = []
        for block in output.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let port = lines.first(where: { $0.hasPrefix("Hardware Port: ") }),
                  let dev = lines.first(where: { $0.hasPrefix("Device: ") }) else { continue }
            let name = String(port.dropFirst(15)), id = String(dev.dropFirst(8))
            if name == "Wi-Fi" || name.contains("Thunderbolt") || name.contains("雷雳") || !id.hasPrefix("en") { continue }
            let config = run("/sbin/ifconfig", [id]).1
            let ip = config.components(separatedBy: "\n").compactMap { line -> String? in
                let words = line.split(whereSeparator: { $0.isWhitespace })
                guard words.count > 1, words[0] == "inet", !words[1].hasPrefix("169.254.") else { return nil }
                return String(words[1])
            }.first ?? ""
            found.append(Adapter(id: id, name: name, active: config.contains("status: active"), ip: ip))
        }
        adapters = found.sorted { $0.active && !$1.active }
        if !found.contains(where: { $0.id == selected }), let first = adapters.first { selected = first.id }
        lastScan = Date()
        if authenticated && adapter?.active != true {
            disconnect(); error = true; message = "网线已断开，请重新连接。"
        }
    }
    func loadPassword() {
        guard let saved = try? CredentialStore.load(),
              saved.account == account, saved.realm == realm else { password = ""; return }
        password = saved.password
    }
    func tick() {
        if Date().timeIntervalSince(lastScan) >= 2 { refresh() }
        if startupPending && adapter?.active == true {
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
        guard let session else { return }
        let text = (try? String(contentsOf: session.appendingPathComponent("events"), encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count > linesRead {
            for line in lines.dropFirst(linesRead) {
                let parts = line.components(separatedBy: "\t"); guard parts.count >= 2 else { continue }
                let state = parts[0], detail = parts.dropFirst().joined(separator: "\t")
                addLog(detail)
                if state == "authenticated" { authenticated = true; retryAttempt = 0; error = false; message = detail }
                else if state == "starting" && !error { message = "正在准备校园网认证…" }
                else if state == "phase" && !authenticated && !error { message = detail }
                else if state == "error" || state == "expired" { error = true; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; message = detail }
                else if state == "stopped" {
                    busy = false; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; terminated = true
                    if !error { message = detail }
                }
            }
            linesRead = lines.count
        }
        let startupTimeout: TimeInterval = authMode == "vendor" ? 60 : 15
        if busy && !authorizing && lines.isEmpty && Date().timeIntervalSince(launchTime) > startupTimeout {
            disconnect(); busy = false; terminated = true; error = true; message = "认证组件未启动，请查看日志或重试管理员授权。"
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
        if authenticated && hasIP && !internet && !checkingInternet && !attemptedInternet { checkInternet() }
    }
    private func waitForAddress() {
        internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false
        message = "正在等待学校服务器分配 IP 地址…"
    }
    func checkInternet() {
        guard let current = session, authenticated, hasIP else { return }
        let testedAddress = adapter?.ip
        checkingInternet = true; attemptedInternet = true
        message = "已取得有线 IP 地址，正在检测网络连通性…"
        Task {
            let result = await Task.detached {
                checkGoogleAndBaidu()
            }.value
            guard session == current, authenticated else { checkingInternet = false; return }
            guard hasIP, adapter?.ip == testedAddress else {
                checkingInternet = false; attemptedInternet = false
                if !hasIP { waitForAddress() }
                return
            }
            googleReachable = result.google; baiduReachable = result.baidu
            internet = result.google || result.baidu
            checkingInternet = false
            message = internet ? "网络连接正常。" : "校园网认证已通过，网络连接测试未通过。"
            addLog("系统网络测试：\(internetDetail)；认证状态单独判定")
            // Mark this attempt as finished; retry only on explicit refresh.
        }
    }
    func manualRefresh() {
        refresh()
        guard authenticated else { return }
        guard hasIP else { waitForAddress(); return }
        if !checkingInternet { attemptedInternet = false; internet = false; googleReachable = nil; baiduReachable = nil; checkInternet() }
    }
    func connect() {
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inode-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let content = "\(selected)\n\(submittedAccount)\n\(password)\n\(xorMode ? 1 : 0)\n\(ProcessInfo.processInfo.processIdentifier)\n\(service)\n\(serviceGBK ? "GBK" : "UTF-8")\n"
            let config = dir.appendingPathComponent("credentials")
            FileManager.default.createFile(atPath: config.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600])
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
                        do { try process.run(); return (0, "") } catch { return (-1, "") }
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
        startupPending = false
        retryDeadline = nil
        userRequestedStop = true
        let hadSession = session != nil
        if let session { FileManager.default.createFile(atPath: session.appendingPathComponent("stop").path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
        authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; message = hadSession ? "正在断开有线认证…" : "已取消自动重试。"
        if session == nil { busy = false }
    }
    func shutdownBroker() {
        if let brokerDirectory { PrivilegeBroker.stop(in: brokerDirectory) }
        brokerDirectory = nil
    }
    private func cleanup() {
        if let session {
            // Do not remove a live session: the helper needs its stop marker.
            if busy { return }
            if terminated || FileManager.default.fileExists(atPath: session.appendingPathComponent("credentials").path) {
                try? FileManager.default.removeItem(at: session)
            }
        }
        session = nil; terminated = false
    }
    #if INODE_TESTING
    func useSyntheticSession(_ directory: URL) {
        session = directory
        linesRead = 0
        busy = true
    }
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
    private var compact: Bool { model.busy || model.retryScheduled || model.authenticated }
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
                step(2, "校园网认证", model.authenticated ? "已通过" : (model.retryScheduled ? "即将重试" : (model.busy ? "认证中" : "等待认证")), model.authenticated)
                step(3, "网络地址", model.hasIP ? "已获取" : (model.authenticated ? "等待获取" : "等待认证"), model.hasIP)
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
                if !model.busy && !model.retryScheduled {
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
                        Picker("有线网卡", selection: $model.selected) {
                            ForEach(model.adapters) { a in Text("\(a.name) · \(a.id)\(a.active ? "（已接入）" : "")").tag(a.id) }
                        }.labelsHidden().disabled(model.busy || model.retryScheduled)
                    }
                    Divider()
                    info("IPv4 地址", "location", model.hasIP ? (model.adapter?.ip ?? "") : (model.authenticated ? "尚未取得有效地址" : "认证后检查地址"))
                    Divider()
                    info("认证状态", "checkmark.shield", model.authenticated ? "校园网认证已通过" : "尚未通过认证")
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
                    actionBar.padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 24)
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
                    Spacer()
                    Button { model.manualRefresh() } label: { Label("刷新状态", systemImage: "arrow.clockwise") }.disabled(model.checkingInternet && model.authenticated)
                    if model.busy || model.retryScheduled {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let connection = Connection()
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 iNode for Mac", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil { entry.target = self }
        item.menu = menu
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(restoreAfterAuthorization),
                                               name: Notification.Name("inodeAuthorizationFinished"), object: nil)

        if !ProcessInfo.processInfo.arguments.contains("--launched-at-login") { openMainWindow() }
        windowSizeObservation = connection.$busy
            .combineLatest(connection.$authenticated, connection.$retryDeadline)
            .map { busy, authenticated, retryDeadline in busy || authenticated || retryDeadline != nil }
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] compact in self?.resizeMainWindow(compact: compact) }
    }

    func menuWillOpen(_ menu: NSMenu) { statusMenuItem?.title = model?.headline ?? "iNode for Mac" }

    @objc private func openMainWindow() {
        guard let model else { return }
        if mainWindow == nil {
            let compact = model.busy || model.retryScheduled || model.authenticated
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
            }))
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
