import Foundation
import Network
import CFNetwork

private final class ProbeCompletion {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false
    private var reachable = false

    func finish(_ value: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        reachable = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(seconds: Int) -> Bool {
        guard semaphore.wait(timeout: .now() + .seconds(seconds)) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }
}

private final class InterfaceCompletion {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false
    private var value: NWInterface?

    func finish(_ interface: NWInterface?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        value = interface
        lock.unlock()
        semaphore.signal()
    }

    func wait(seconds: Int) -> NWInterface? {
        guard semaphore.wait(timeout: .now() + .seconds(seconds)) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func selectedNetworkInterface(named name: String) -> NWInterface? {
    let monitor = NWPathMonitor()
    let completion = InterfaceCompletion()
    monitor.pathUpdateHandler = { path in
        completion.finish(path.availableInterfaces.first { $0.name == name && $0.type == .wiredEthernet })
    }
    monitor.start(queue: DispatchQueue(label: "inode.ethernet-path"))
    defer { monitor.cancel() }
    return completion.wait(seconds: 2)
}

private func directHTTPS(host: String, path: String, expectedStatus: ClosedRange<Int>,
                         interface: NWInterface, address: String) -> Bool {
    let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
    parameters.requiredInterface = interface
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
    let connection = NWConnection(host: NWEndpoint.Host(host), port: .https, using: parameters)
    let completion = ProbeCompletion()
    let queue = DispatchQueue(label: "inode.direct-https.\(host)")
    var response = Data()

    func receiveStatus() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let data { response.append(data) }
            if let end = response.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: response[..<end.lowerBound], as: UTF8.self)
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                let status = fields.count > 1 && fields[0].hasPrefix("HTTP/1.") ? Int(fields[1]) : nil
                completion.finish(status.map(expectedStatus.contains) ?? false)
            } else if error != nil || isComplete || response.count >= 4096 {
                completion.finish(false)
            } else {
                receiveStatus()
            }
        }
    }

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if error != nil { completion.finish(false) }
                else { receiveStatus() }
            })
        case .failed, .cancelled:
            completion.finish(false)
        default:
            break
        }
    }
    connection.start(queue: queue)
    let reachable = completion.wait(seconds: 6)
    connection.cancel()
    return reachable
}

// A raw TLS connection does not consult macOS HTTP proxy settings. Both the interface
// and its current IPv4 address are required, so another active network cannot pass.
func directEthernetHTTPSChecks(interface name: String, address: String) -> (google: Bool, baidu: Bool) {
    guard let interface = selectedNetworkInterface(named: name) else { return (false, false) }
    let googleCompletion = ProbeCompletion()
    DispatchQueue.global(qos: .utility).async {
        googleCompletion.finish(directHTTPS(host: "www.google.com", path: "/generate_204",
                                            expectedStatus: 204...204, interface: interface, address: address))
    }
    let baidu = directHTTPS(host: "www.baidu.com", path: "/", expectedStatus: 200...299,
                            interface: interface, address: address)
    return (googleCompletion.wait(seconds: 7), baidu)
}

func publicIPv4Answers(from data: Data) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["Status"] as? Int == 0,
          let answers = object["Answer"] as? [[String: Any]] else { return [] }
    return answers.compactMap { answer in
        guard answer["type"] as? Int == 1, let ip = answer["data"] as? String else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, ip, &address) == 1 else { return nil }
        let octets = withUnsafeBytes(of: address.s_addr) { Array($0) }
        let first = octets[0], second = octets[1], third = octets[2]
        if first == 0 || first == 10 || first == 127 || first >= 224 ||
           (first == 100 && (64...127).contains(second)) ||
           (first == 169 && second == 254) ||
           (first == 172 && (16...31).contains(second)) ||
           (first == 192 && (second == 0 || second == 168)) ||
           (first == 198 && (second == 18 || second == 19 || (second == 51 && third == 100))) ||
           (first == 203 && second == 0 && third == 113) { return nil }
        return ip
    }
}

// Google DoH supplies real destination addresses even when a local proxy's DNS
// returns 198.18/15 fake addresses. The DoH request never counts as an online
// result: the final HTTPS request must still succeed on the selected Ethernet.
private func systemHTTPSProxy() -> String? {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
          settings[kCFNetworkProxiesHTTPSEnable as String] as? Int == 1,
          let host = settings[kCFNetworkProxiesHTTPSProxy as String] as? String, !host.isEmpty,
          let port = settings[kCFNetworkProxiesHTTPSPort as String] as? Int,
          (1...65535).contains(port) else { return nil }
    let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return "http://\(address):\(port)"
}

func dnsPinnedBaiduHTTPS(on interface: String) -> Bool {
    let resolver = Process()
    resolver.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    resolver.arguments = ["-q", "--ipv4", "--fail", "--silent", "--connect-timeout", "3",
                          "--max-time", "5", "--max-filesize", "8192",
                          "https://dns.google/resolve?name=www.baidu.com&type=A"]
    if let proxy = systemHTTPSProxy() { resolver.arguments?.insert(contentsOf: ["--proxy", proxy], at: 1) }
    let output = Pipe()
    resolver.standardOutput = output
    resolver.standardError = FileHandle.nullDevice
    do { try resolver.run() } catch { return false }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    resolver.waitUntilExit()
    guard resolver.terminationStatus == 0 else { return false }
    for ip in publicIPv4Answers(from: data).prefix(2) {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        probe.arguments = ["-q", "--ipv4", "--interface", "if!\(interface)", "--proxy", "",
                           "--noproxy", "*", "--proto", "=https", "--resolve", "www.baidu.com:443:\(ip)",
                           "--connect-timeout", "3", "--max-time", "5", "--max-redirs", "0",
                           "--silent", "--output", "/dev/null", "--write-out", "%{http_code}",
                           "https://www.baidu.com/"]
        let result = Pipe()
        probe.standardOutput = result
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { continue }
        let response = result.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let code = Int(String(decoding: response, as: UTF8.self)) ?? 0
        if probe.terminationStatus == 0 && (200...299).contains(code) { return true }
    }
    return false
}
