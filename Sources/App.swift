import SwiftUI
import AppKit
import Security

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
enum PasswordStore {
    static let service = "local.swufe.inode-mac"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load(_ account: String) -> String {
        guard !account.isEmpty else { return "" }
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    static func save(_ account: String, _ password: String) -> Bool {
        let q = query(account)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let update = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        if update != errSecItemNotFound { return false }
        var new = q; new[kSecValueData as String] = Data(password.utf8)
        new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(new as CFDictionary, nil) == errSecSuccess
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
@MainActor final class Connection: ObservableObject {
    @Published var showLog = false
    @Published var adapters: [Adapter] = []
    @Published var selected = UserDefaults.standard.string(forKey: "adapter") ?? "en8"
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var password = ""
    @Published var realm = UserDefaults.standard.string(forKey: "realm") ?? "移动"
    @Published var authMode = UserDefaults.standard.string(forKey: "authMode") ?? "vendor"
    @Published var remember = UserDefaults.standard.bool(forKey: "remember")
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
    var account: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var submittedAccount: String { campusSubmittedAccount(account, realm: realm) }
    var credentialKey: String { account + "|service:" + realm.trimmingCharacters(in: .whitespacesAndNewlines) }

    var adapter: Adapter? { adapters.first { $0.id == selected } }
    var hasIP: Bool { !(adapter?.ip ?? "").isEmpty }
    var internetDetail: String {
        if checkingInternet { return "正在测试 Google 和百度" }
        if !attemptedInternet { return "尚未测试 Google 和百度" }
        return "Google：\(googleReachable == true ? "可访问" : "未通过") · 百度：\(baiduReachable == true ? "可访问" : "未通过")"
    }
    init() {
        password = PasswordStore.load(credentialKey)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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
    func loadPassword() { password = PasswordStore.load(credentialKey) }
    func tick() {
        if Date().timeIntervalSince(lastScan) > 4 { refresh() }
        guard let session else { return }
        let text = (try? String(contentsOf: session.appendingPathComponent("events"), encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count > linesRead {
            for line in lines.dropFirst(linesRead) {
                let parts = line.components(separatedBy: "\t"); guard parts.count >= 2 else { continue }
                let state = parts[0], detail = parts.dropFirst().joined(separator: "\t")
                addLog(detail)
                if state == "authenticated" { authenticated = true; error = false; message = detail }
                else if state == "error" || state == "expired" { error = true; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; message = detail }
                else if state == "stopped" {
                    busy = false; authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; terminated = true
                    if !error { message = detail }
                } else if !authenticated && !error { message = detail }
            }
            linesRead = lines.count
        }
        if busy && !authorizing && lines.isEmpty && Date().timeIntervalSince(launchTime) > 15 {
            disconnect(); busy = false; terminated = true; error = true; message = "认证组件未启动，请查看日志或重试管理员授权。"
        }
        if terminated { cleanup(); return }
        if authenticated && hasIP && !internet && !checkingInternet && !attemptedInternet { checkInternet() }
        if authenticated && !hasIP { message = "认证已通过，正在等待有线 IPv4 地址。" }
    }
    func checkInternet() {
        guard let current = session else { return }
        checkingInternet = true; attemptedInternet = true
        Task {
            let result = await Task.detached {
                checkGoogleAndBaidu()
            }.value
            guard session == current, authenticated else { checkingInternet = false; return }
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
        if authenticated && !checkingInternet { attemptedInternet = false; internet = false; googleReachable = nil; baiduReachable = nil; checkInternet() }
    }
    func connect() {
        guard !busy else { return }
        guard adapter?.active == true else { error = true; message = "请先插好网线，并选择已接入的有线网卡。"; return }
        let service = realm.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = [selected, submittedAccount, password, service]
        guard !account.isEmpty, !password.isEmpty, service.utf8.count <= 64, values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") && $0.utf8.count <= 240 }) else {
            error = true; message = "请填写有效的账号和密码。"; return
        }
        UserDefaults.standard.set(username, forKey: "username"); UserDefaults.standard.set(realm, forKey: "realm")
        UserDefaults.standard.set(selected, forKey: "adapter"); UserDefaults.standard.set(remember, forKey: "remember")
        UserDefaults.standard.set(xorMode, forKey: "xorMode")
        UserDefaults.standard.set(serviceGBK, forKey: "serviceGBK")
        UserDefaults.standard.set(authMode, forKey: "authMode")
        if remember {
            if !PasswordStore.save(credentialKey, password) { addLog("密码未能保存到钥匙串，本次连接仍可继续") }
        } else { PasswordStore.delete(credentialKey) }
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
            launchTime = Date(); message = usePEAP ? "正在启动 macOS 有线 PEAP 认证…" : "请在 macOS 弹窗中允许有线认证。"; addLog("准备启动有线认证组件（\(selected)）")
            addLog(submittedAccount != account ? "移动账号按学校 Mac 教程补全 @cm；密码未改动" : "使用填写的账号格式；密码未改动")
            guard let helper = Bundle.main.url(forResource: "inode-helper", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            let command = shellQuote(helper.path) + " --session " + shellQuote(dir.path) + " >/dev/null 2>&1 &"
            let script = "do shell script " + appleQuote(command) + " with administrator privileges"
            Task {
                let result = await Task.detached { () -> (Int32, String) in
                    if usePEAP {
                        let process = Process(); process.executableURL = helper
                        process.arguments = ["--peap-session", dir.path]
                        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                        do { try process.run(); return (0, "") } catch { return (-1, "") }
                    }
                    return run("/usr/bin/osascript", ["-e", script])
                }.value
                guard session == dir else { return }
                authorizing = false
                if result.0 != 0 {
                    busy = false; error = true; message = usePEAP ? "PEAP 认证组件启动失败。" : "管理员授权取消或启动失败。"; addLog(message); cleanup()
                } else { launchTime = Date(); message = "正在启动有线认证…" }
            }
        } catch { busy = false; self.error = true; message = "无法启动认证组件：\(error.localizedDescription)"; cleanup() }
    }
    func disconnect() {
        if let session { FileManager.default.createFile(atPath: session.appendingPathComponent("stop").path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
        authenticated = false; internet = false; googleReachable = nil; baiduReachable = nil; attemptedInternet = false; message = "正在断开有线认证…"
        if session == nil { busy = false }
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
    func forgetPassword() { PasswordStore.delete(credentialKey); password = ""; remember = false; UserDefaults.standard.set(false, forKey: "remember"); addLog("已移除此账号的钥匙串密码") }
}

let green = Color(red: 0.08, green: 0.55, blue: 0.36)
struct ContentView: View {
    @StateObject var model = Connection()
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "network").font(.system(size: 24, weight: .semibold)).foregroundStyle(green)
                    VStack(alignment: .leading, spacing: 3) { Text("iNode for Mac").font(.headline); Text("西南财经大学").font(.caption).foregroundStyle(.secondary) }
                }.padding(.bottom, 18)
                Text("连接步骤").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                step(1, "有线链路", model.adapter?.active == true ? "网线已接入" : "等待接入", model.adapter?.active == true)
                step(2, "校园网认证", model.authenticated ? "已通过" : (model.busy ? "认证中" : "等待认证"), model.authenticated)
                step(3, "网络地址", model.hasIP ? "已获取" : "等待获取", model.hasIP)
                Spacer()
            }.padding(26).frame(width: 225).frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 22) {
                    Image(systemName: model.internet ? "checkmark.circle.fill" : (model.error ? "exclamationmark.circle.fill" : "cable.connector"))
                        .font(.system(size: 52, weight: .light)).foregroundStyle(model.error ? .orange : green)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.internet ? "已连接" : (model.authenticated ? "认证已通过" : (model.error ? "需要处理" : (model.busy ? "正在连接" : "连接校园网"))))
                            .font(.system(size: 30, weight: .bold))
                        Text(model.message).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.busy && !model.authenticated { ProgressView().controlSize(.small) }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(green.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                if !model.busy {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack { Text("校园网账号").font(.headline); Spacer(); Text("宿舍有线 · 移动").font(.caption).foregroundStyle(.secondary) }
                        HStack(spacing: 14) {
                            field("学号 / 完整账号") { TextField("请输入学号", text: $model.username).onSubmit { model.loadPassword() } }
                            field("密码") { SecureField("校园网密码", text: $model.password) }
                        }
                        HStack {
                            Toggle("保存到 macOS 钥匙串", isOn: $model.remember).toggleStyle(.checkbox)
                            Spacer()
                            Button("清除已保存密码") { model.forgetPassword() }.buttonStyle(.link)
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
                        }.labelsHidden().disabled(model.busy)
                    }
                    Divider()
                    info("IPv4 地址", "location", model.adapter?.ip.isEmpty == false ? model.adapter!.ip : "尚未取得有效地址")
                    Divider()
                    info("认证状态", "checkmark.shield", model.authenticated ? "校园网认证已通过" : "尚未通过认证")
                    Divider()
                    info("网站访问", "globe", model.internetDetail)
                }.padding(22).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
                Spacer(minLength: 0)
                HStack {
                    Button { model.showLog = true } label: { Label("连接日志", systemImage: "list.bullet.rectangle") }
                    Spacer()
                    Button { model.manualRefresh() } label: { Label("刷新状态", systemImage: "arrow.clockwise") }.disabled(model.checkingInternet && model.authenticated)
                    if model.busy {
                        Button(role: .destructive) { model.disconnect() } label: { Label("断开连接", systemImage: "xmark") }
                    } else {
                        Button { model.connect() } label: { Label("连接校园网", systemImage: "bolt.fill") }.buttonStyle(.borderedProminent).tint(green)
                    }
                }.controlSize(.large)
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 920, minHeight: 770).background(Color(nsColor: .windowBackgroundColor))
            .background(MinimizeOnClose().frame(width: 0, height: 0))
            .sheet(isPresented: $model.showLog) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("连接日志").font(.title2.bold()); Spacer(); Button("关闭") { model.showLog = false } }
                    Text("记录认证阶段、错误及已脱敏的通知，不记录账号、密码或原始报文。").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(model.logs.isEmpty ? "暂无认证日志。" : model.logs.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.logs.joined(separator: "\n"), forType: .string) }
                }.padding(24).frame(width: 690, height: 420)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.disconnect() }
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
@main struct InodeMac: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    var body: some Scene {
        WindowGroup("iNode for Mac") { ContentView() }.windowStyle(.titleBar).defaultSize(width: 980, height: 780)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
