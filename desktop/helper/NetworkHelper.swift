// OPL NetFleet macOS network owner. Original implementation using Apple's public
// SystemConfiguration and POSIX APIs; no Clash project code is incorporated.
import Foundation
import SystemConfiguration
import Darwin

let rootDir = "/var/db/opl-netfleet-network"
let runDir = "/var/run/opl-netfleet-network"
let socketPath = runDir + "/control.sock"
let journalPath = rootDir + "/system-proxies.json"
let recoveryPath = runDir + "/recovery-required"
let corePath = "/Library/Application Support/OPL NetFleet/Privileged/mihomo"
let fm = FileManager.default
struct Failure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func writePrivate(_ object: Any, _ path: String) throws {
    try jsonData(object).write(to: URL(fileURLWithPath: path), options: .atomic)
    chmod(path, 0o600)
}
func readJSON(_ path: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw Failure("Invalid JSON object") }
    return value
}
func secureDirectory(_ path: String, mode: mode_t) throws {
    var st = stat()
    if lstat(path, &st) == 0 {
        try require(st.st_uid == 0 && (st.st_mode & S_IFMT) == S_IFDIR && (st.st_mode & 0o022) == 0, "Unsafe root state directory")
    } else { try fm.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: mode)]) }
}
func identity(_ pid: pid_t) -> String? {
    guard pid > 1, kill(pid, 0) == 0 else { return nil }
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "uid=,lstart="]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    } catch { return nil }
}
func ownerUID(_ identity: String) throws -> uid_t {
    guard let first = identity.split(whereSeparator: { $0.isWhitespace }).first, let uid = uid_t(first), uid > 0 else { throw Failure("Owner must be a live non-root desktop process") }
    return uid
}
func interfaceExists(_ name: String) -> Bool { if_nametoindex(name) != 0 }
func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
    if lhs == nil && rhs == nil { return true }
    guard let lhs, let rhs else { return false }
    return NSDictionary(dictionary: ["v": lhs]).isEqual(to: ["v": rhs])
}

func restoredProxyKeys(current original: [String: Any], before: [String: Any], expected: [String: Any]) -> [String: Any] {
    var current = original
    for (key, value) in expected where equal(current[key], value) {
        if before[key] is NSNull { current.removeValue(forKey: key) } else { current[key] = before[key] }
    }
    return current
}

// Save only keys we modify, keyed by stable SCNetworkService ID. Restoring uses
// compare-and-swap per key, retaining changes made by another VPN or the user.
func withPreferences<T>(_ body: (SCPreferences, [SCNetworkService]) throws -> T) throws -> T {
    guard let prefs = SCPreferencesCreate(nil, "OPL NetFleet" as CFString, nil) else { throw Failure("Cannot open network preferences") }
    try require(SCPreferencesLock(prefs, true), "Cannot lock network preferences")
    defer { SCPreferencesUnlock(prefs) }
    SCPreferencesSynchronize(prefs)
    let services = (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]) ?? []
    return try body(prefs, services)
}
func commit(_ prefs: SCPreferences) throws {
    try require(SCPreferencesCommitChanges(prefs), "Cannot commit network preferences")
    try require(SCPreferencesApplyChanges(prefs), "Cannot apply network preferences")
}
func attachSystem(port: Int) throws {
    try withPreferences { prefs, services in
        let expected: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        var rows: [[String: Any]] = []
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies), let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
            let original = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            var saved: [String: Any] = [:]
            for key in expected.keys { saved[key] = original[key] ?? NSNull() }
            rows.append(["serviceID": serviceID as String, "before": saved, "expected": expected])
        }
        try require(!rows.isEmpty, "No configurable network services")
        // Durable rollback precedes the first mutation.
        try writePrivate(["services": rows], journalPath)
        try Data().write(to: URL(fileURLWithPath: recoveryPath), options: .atomic)
        chmod(recoveryPath, 0o644)
        for row in rows {
            let id = row["serviceID"] as! String
            guard let service = services.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == id }), let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { throw Failure("Network service changed during attach") }
            var config = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            for (key, value) in expected { config[key] = value }
            try require(SCNetworkProtocolSetConfiguration(proto, config as CFDictionary), "Cannot update proxy preferences")
        }
        try commit(prefs)
    }
    try withPreferences { _, services in
        for row in (try readJSON(journalPath))["services"] as? [[String: Any]] ?? [] {
            let id = row["serviceID"] as! String
            guard let service = services.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == id }), let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { throw Failure("Missing network service after attach") }
            let actual = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            for (key, value) in row["expected"] as! [String: Any] { try require(equal(actual[key], value), "Proxy setting readback failed") }
        }
    }
}
func systemSettingsMatch() -> Bool {
    guard let journal = try? readJSON(journalPath), let rows = journal["services"] as? [[String: Any]] else { return false }
    return (try? withPreferences { _, services in
        for row in rows {
            guard let id = row["serviceID"] as? String, let expected = row["expected"] as? [String: Any], let service = services.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == id }), let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { return false }
            let current = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            for (key, value) in expected where !equal(current[key], value) { return false }
        }
        return true
    }) ?? false
}
func restoreSystem() throws {
    guard fm.fileExists(atPath: journalPath) else { try? fm.removeItem(atPath: recoveryPath); return }
    let rows = (try readJSON(journalPath))["services"] as? [[String: Any]] ?? []
    try withPreferences { prefs, services in
        for row in rows {
            guard let id = row["serviceID"] as? String, let before = row["before"] as? [String: Any], let expected = row["expected"] as? [String: Any], let service = services.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == id }), let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let current = restoredProxyKeys(current: (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:], before: before, expected: expected)
            try require(SCNetworkProtocolSetConfiguration(proto, current as CFDictionary), "Cannot restore proxy preferences")
        }
        try commit(prefs)
    }
    // SCPreferences readback after a separate synchronize verifies persisted values.
    try withPreferences { _, services in
        for row in rows {
            guard let id = row["serviceID"] as? String, let before = row["before"] as? [String: Any], let expected = row["expected"] as? [String: Any], let service = services.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == id }), let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let current = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            for (key, value) in expected where !equal(before[key] is NSNull ? nil : before[key], value) {
                try require(!equal(current[key], value), "Proxy restoration remains unconfirmed")
            }
        }
    }
    try fm.removeItem(atPath: journalPath)
    try? fm.removeItem(atPath: recoveryPath)
}

// Root copies only files within this session's private state, read with the
// invoking user's effective UID. The core never consumes user-controlled paths.
func userData(_ file: String, within base: String, uid: uid_t) throws -> Data {
    let resolved = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
    let root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
    try require(resolved.hasPrefix(root + "/"), "Configuration file escapes desktop state")
    try require(seteuid(uid) == 0, "Cannot assume owner identity for configuration read")
    defer { seteuid(0) }
    let handle = open(resolved, O_RDONLY | O_NOFOLLOW)
    try require(handle >= 0, "Configuration is unreadable by desktop owner")
    defer { close(handle) }
    var st = stat(); try require(fstat(handle, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_size <= 32 * 1024 * 1024, "Invalid configuration file")
    let fh = FileHandle(fileDescriptor: handle, closeOnDealloc: false)
    return try fh.readToEnd() ?? Data()
}
func prepareTun(configPath: String, base: String, uid: uid_t, port: Int) throws -> String {
    let bytes = try userData(configPath, within: base, uid: uid)
    // A fresh session must never inherit another account's provider cache.
    for filename in try fm.contentsOfDirectory(atPath: rootDir) where filename == "config.json" || filename.hasPrefix("proxy-providers-") || filename.hasPrefix("rule-providers-") {
        try fm.removeItem(atPath: rootDir + "/" + filename)
    }
    guard let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure("TUN configuration must be JSON") }
    let allowed = ["proxies", "proxy-groups", "rules", "dns", "hosts", "sniffer", "mode", "log-level", "ipv6", "unified-delay", "tcp-concurrent", "find-process-mode", "keep-alive-interval", "keep-alive-idle", "secret"]
    var config: [String: Any] = [:]
    for key in allowed { config[key] = input[key] }
    guard let controller = input["external-controller"] as? String, controller.hasPrefix("127.0.0.1:"), let controllerPort = Int(controller.split(separator: ":").last ?? ""), controllerPort >= 1024, controllerPort <= 65535 else { throw Failure("Controller must use a high loopback port") }
    config["external-controller"] = controller
    config["mixed-port"] = port; config["bind-address"] = "127.0.0.1"; config["allow-lan"] = false
    config["profile"] = ["store-selected": false, "store-fake-ip": false]
    var dns = config["dns"] as? [String: Any] ?? [:]
    dns.removeValue(forKey: "listen"); dns["enable"] = true
    config["dns"] = dns
    config["tun"] = ["enable": true, "device": "utun198", "stack": "gvisor", "auto-route": true, "auto-detect-interface": true, "strict-route": false, "dns-hijack": ["any:53"]]
    for category in ["proxy-providers", "rule-providers"] {
        guard let providers = input[category] as? [String: [String: Any]] else { continue }
        var mapped: [String: Any] = [:]
        for (index, entry) in providers.sorted(by: { $0.key < $1.key }).enumerated() {
            let (name, original) = entry; var provider = original
            let destination = rootDir + "/\(category)-\(index).yaml"
            if (provider["type"] as? String) == "file" {
                guard let source = provider["path"] as? String else { throw Failure("Missing provider file") }
                let fullPath = source.hasPrefix("/") ? source : URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent(source).path
                try userData(fullPath, within: base, uid: uid).write(to: URL(fileURLWithPath: destination), options: .atomic)
                chmod(destination, 0o600)
            } else { try require((provider["type"] as? String) == "http", "Unsupported provider type") }
            provider["path"] = destination; mapped[name] = provider
        }
        config[category] = mapped
    }
    let destination = rootDir + "/config.json"
    try writePrivate(config, destination)
    let check = Process(); check.executableURL = URL(fileURLWithPath: corePath)
    check.arguments = ["-t", "-d", rootDir, "-f", destination]
    check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
    try check.run()
    for _ in 0..<300 where check.isRunning { usleep(100000) }
    if check.isRunning { check.terminate(); usleep(200000); if check.isRunning { kill(check.processIdentifier, SIGKILL) } }
    check.waitUntilExit(); try require(check.terminationStatus == 0, "Privileged configuration validation failed")
    return destination
}

var stopping = false
signal(SIGTERM) { _ in stopping = true }
signal(SIGINT) { _ in stopping = true }
signal(SIGHUP) { _ in stopping = true }
signal(SIGPIPE, SIG_IGN)

func makeSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try require(fd >= 0, "Cannot create helper socket")
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    unlink(socketPath)
    let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    try require(result == 0 && listen(fd, 4) == 0, "Cannot bind helper socket")
    chmod(socketPath, 0o666)
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    return fd
}
func reply(_ fd: Int32, _ object: [String: Any]) { if let data = try? jsonData(object) { let bytes = data + Data([10]); bytes.withUnsafeBytes { _ = send(fd, $0.baseAddress, bytes.count, 0) } } }

func run() throws {
    try require(getuid() == 0, "Administrator authorization is required")
    let args = CommandLine.arguments
    try require(args.count >= 6 && args[1] == "attach" && ["system", "tun"].contains(args[2]), "usage: helper attach system|tun ownerPid port corePid|configPath [stateDir]")
    let mode = args[2]
    guard let ownerPid = pid_t(args[3]), let port = Int(args[4]), port >= 1024 && port <= 65535, let ownerIdentity = identity(ownerPid) else { throw Failure("Invalid session owner or port") }
    let uid = try ownerUID(ownerIdentity)
    try secureDirectory(rootDir, mode: 0o700); try secureDirectory(runDir, mode: 0o755)
    let lock = open(runDir + "/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    try require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "Another network owner is active")
    defer { close(lock) }
    try restoreSystem()
    let socketFD = try makeSocket()
    defer { close(socketFD); unlink(socketPath) }
    var core: Process? = nil
    var corePid: pid_t = 0
    var coreIdentity: String? = nil
    var failure: String? = nil
    var active = false
    try require(args.count == 7, "Network session requires private desktop state")
    let stateBase = args[6]
    func clean() throws {
        var problems: [String] = []
        do { try restoreSystem() } catch { problems.append(String(describing: error)) }
        if let process = core, process.isRunning {
            process.terminate()
            for _ in 0..<50 where process.isRunning { usleep(100000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        core = nil; corePid = 0; coreIdentity = nil; active = false
        if mode == "tun" && interfaceExists("utun198") { problems.append("Owned TUN interface still exists after core exit") }
        try require(problems.isEmpty, problems.joined(separator: "; "))
    }
    defer { try? clean() }
    func activate(_ argument: String) throws {
        try require(!active, "Network session is already active")
        try clean()
        if mode == "system" {
            guard let pid = pid_t(argument), let ident = identity(pid), try ownerUID(ident) == uid else { throw Failure("Core must belong to the desktop user") }
            corePid = pid; coreIdentity = ident
            try attachSystem(port: port)
        } else {
            try require(!interfaceExists("utun198"), "TUN interface is already owned")
            let config = try prepareTun(configPath: argument, base: stateBase, uid: uid, port: port)
            let process = Process(); process.executableURL = URL(fileURLWithPath: corePath)
            process.arguments = ["-d", rootDir, "-f", config]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); core = process; corePid = process.processIdentifier; coreIdentity = identity(corePid)
            for _ in 0..<100 where !interfaceExists("utun198") && process.isRunning { usleep(100000) }
            try require(process.isRunning && interfaceExists("utun198"), "Mihomo failed to establish TUN")
        }
        active = true; failure = nil
    }
    func attempt(_ argument: String) {
        do { try activate(argument) }
        catch { failure = String(describing: error); do { try clean() } catch { failure! += "; cleanup: \(error)" } }
    }
    func state() -> [String: Any] {
        let confirmed = active && (mode != "system" || systemSettingsMatch()) && (mode != "tun" || interfaceExists("utun198"))
        var status: [String: Any] = ["mode": mode, "ownerPid": ownerPid, "helperPid": getpid(), "corePid": corePid, "running": active, "phase": active ? (confirmed ? "active" : "changed") : "idle", "recoveryRequired": !active && (fm.fileExists(atPath: journalPath) || (mode == "tun" && interfaceExists("utun198")))]
        if let failure { status["error"] = failure }
        else if active && !confirmed { status["error"] = "Network settings changed outside this session" }
        return status
    }
    attempt(args[5])
    var nextHealthCheck = Date()
    while !stopping {
        let client = accept(socketFD, nil, nil)
        if client >= 0 {
            var peerUID: uid_t = 0; var peerGID: gid_t = 0
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            if getpeereid(client, &peerUID, &peerGID) == 0 && peerUID == uid {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(client, &buffer, buffer.count)
                let request = count > 0 ? (try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any]) : nil
                if request?["action"] as? String == "status" { reply(client, state()) }
                else if request?["ownerPid"] as? Int == Int(ownerPid) {
                    if request?["action"] as? String == "detach" {
                        do {
                            try clean(); failure = nil
                            reply(client, ["ok": true, "status": "detached"])
                            stopping = request?["close"] as? Bool == true
                        } catch { reply(client, ["ok": false, "status": "recovery-required", "error": String(describing: error)]) }
                    } else if request?["action"] as? String == "attach" {
                        if mode == "system", let pid = request?["corePid"] as? Int { attempt(String(pid)) }
                        else if mode == "tun", let configPath = request?["configPath"] as? String { attempt(configPath) }
                        else { failure = "Invalid attach request" }
                        var result = state(); result["ok"] = active; reply(client, result)
                    } else { reply(client, ["ok": false, "status": "forbidden"]) }
                } else { reply(client, ["ok": false, "status": "forbidden"]) }
            } else { reply(client, ["ok": false, "status": "forbidden"]) }
            close(client)
        }
        if Date() >= nextHealthCheck {
            if identity(ownerPid) != ownerIdentity { stopping = true }
            else if active && identity(corePid) != coreIdentity {
                do { try clean(); failure = "Core exited; network access restored" }
                catch { failure = "Core exited; cleanup: \(error)" }
            }
            nextHealthCheck = Date().addingTimeInterval(1)
        }
        usleep(100000)
    }
    try clean()
}

func selfTest() throws {
    let before: [String: Any] = ["HTTPEnable": 0, "HTTPPort": NSNull(), "ProxyAutoConfigEnable": 1]
    let expected: [String: Any] = ["HTTPEnable": 1, "HTTPPort": 17890, "ProxyAutoConfigEnable": 0]
    let restored = restoredProxyKeys(current: ["HTTPEnable": 1, "HTTPPort": 17890, "ProxyAutoConfigEnable": 0, "Other": "preserve"], before: before, expected: expected)
    try require(equal(restored["HTTPEnable"], 0) && restored["HTTPPort"] == nil && equal(restored["ProxyAutoConfigEnable"], 1) && equal(restored["Other"], "preserve"), "Rollback must restore missing keys and PAC state")
    let changed = restoredProxyKeys(current: ["HTTPEnable": 0, "HTTPPort": 9999, "ProxyAutoConfigEnable": 1], before: before, expected: expected)
    try require(equal(changed["HTTPPort"], 9999), "Rollback must preserve third-party changes")
    try require(identity(getpid()) != nil && identity(-1) == nil, "Process identity validation")
    print("network helper self-test passed (no network changes)")
}
do {
    if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] { try selfTest() }
    else { try run() }
} catch { fputs("NetFleet helper: \(error)\n", stderr); exit(1) }
