import CodexProxyLauncherCore
import Darwin
import Foundation

@main
struct CodexNativeProxy {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "prepare-authorization" {
                let owner = option("--owner-pid", arguments).flatMap(Int32.init)
                let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
                let command = try await MainActor.run {
                    try NativeProxyClient(helperURL: helper).authorizationCommand(proxy: ProxySettings(), ownerPID: owner)
                }
                print(command.path)
                return
            }
            if arguments.first == "stop" {
                let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
                let client = await MainActor.run { NativeProxyClient(helperURL: helper) }
                try await client.stop()
                print("Native compatibility proxy stopped; original settings restored.")
                return
            }
            if arguments.first == "probe" {
                async let system = NativeNetworkDiagnostics.probe()
                async let explicit = NativeNetworkDiagnostics.probe(proxy: ProxySettings())
                let results = await ["system": system, "explicit": explicit]
                print(String(data: try JSONEncoder().encode(results), encoding: .utf8)!)
                return
            }
            if arguments.first == "status" {
                let record = try NativeProxySession.read(from: stateFile(arguments))
                print("status=\(record.status) service=\(record.snapshot.serviceName) helper=\(record.helperPID)")
                return
            }
            guard arguments.first == "serve" else { throw NativeProxyError.helperFailed("用法：probe | status | serve --owner-pid PID") }
            try await serve(arguments)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func option(_ key: String, _ args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func stateFile(_ args: [String]) -> URL {
        option("--state-file", args).map { URL(fileURLWithPath: $0) } ?? NativeProxySession.defaultFile
    }

    private static func serve(_ args: [String]) async throws {
        guard let rawOwner = option("--owner-pid", args), let owner = Int32(rawOwner), owner > 1 else {
            throw NativeProxyError.helperFailed("缺少有效 owner PID")
        }
        let port = UInt16(option("--proxy-port", args) ?? "7890") ?? 0
        let proxy = ProxySettings(host: option("--proxy-host", args) ?? "127.0.0.1", port: port)
        _ = try NativeProxyPolicy.javaScript(proxy: proxy)
        guard let ownerUID = NativeProxySession.processUID(owner), ownerUID > 0 else {
            throw NativeProxyError.helperFailed("无法确认启动器用户身份")
        }
        let file = stateFile(args)
        guard geteuid() != 0 || file == NativeProxySession.file(for: ownerUID) else {
            throw NativeProxyError.helperFailed("拒绝非标准管理员会话路径")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: geteuid() == 0 ? 0o755 : 0o700])
        if geteuid() == 0 {
            let directory = file.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0,
                  !((try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true) else {
                throw NativeProxyError.helperFailed("管理员会话目录权限不安全")
            }
        }
        let lockFD = open(file.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw NativeProxyError.helperFailed("无法创建会话锁") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw NativeProxyError.helperFailed("兼容代理已有运行实例") }
        if let stale = try? NativeProxySession.read(from: file),
           SystemProxyStore.isActive(stale.pacURL, serviceID: stale.snapshot.serviceID) {
            guard !NativeProxySession.processIsAlive(stale.helperPID) else { throw NativeProxyError.helperFailed("已有活动助手") }
            try SystemProxyStore.restore(snapshot: stale.snapshot, ownedURL: stale.pacURL)
        }
        guard await ProxyReachability.check(settings: proxy) else { throw NativeProxyError.helperFailed("Clash 端口不可达") }
        let snapshot = try SystemProxyStore.capture()
        let server = try LoopbackPACServer(proxy: proxy)
        let url = try await server.start()
        var record = NativeProxySession(ownerPID: owner, proxy: proxy, pacURL: url, snapshot: snapshot)
        try record.write(to: file)
        let stopped = StopFlag(ownerPID: owner)
        let controlToken = record.controlToken
        server.controlHandler = { action, authorization in
            guard authorization == "Bearer " + controlToken else { return false }
            if action == "stop" { stopped.set(); return true }
            if action.hasPrefix("adopt/"), let pid = Int32(action.dropFirst(6)),
               NativeProxySession.processUID(pid) == ownerUID { stopped.adopt(pid); return true }
            return false
        }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let signals = [SIGTERM, SIGINT, SIGHUP].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { stopped.set() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() }; server.stop() }
        do {
            try SystemProxyStore.install(url: url, snapshot: snapshot)
            record.status = "active"
            try record.write(to: file)
            print("Native proxy active on \(snapshot.serviceName)")
            var ownerMissingSince: Date?
            var unavailable = 0
            while !stopped.value {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if record.ownerPID != stopped.ownerPID {
                    record.ownerPID = stopped.ownerPID
                    try record.write(to: file)
                }
                if NativeProxySession.processIsAlive(record.ownerPID) { ownerMissingSince = nil }
                else {
                    if ownerMissingSince == nil { ownerMissingSince = Date() }
                    if Date().timeIntervalSince(ownerMissingSince!) >= 5 { break }
                }
                if !SystemProxyStore.isActive(url, serviceID: snapshot.serviceID) { break }
                if (try? SystemProxyStore.capture().serviceID) != snapshot.serviceID {
                    record.detail = "活动网络已切换，原代理设置已恢复，请重新开启兼容模式。"
                    break
                }
                unavailable = await ProxyReachability.check(settings: proxy) ? 0 : unavailable + 1
                if unavailable >= 3 { record.detail = "Clash 已停止，原代理设置已恢复。"; break }
            }
            if SystemProxyStore.isActive(url, serviceID: snapshot.serviceID) {
                try SystemProxyStore.restore(snapshot: snapshot, ownedURL: url)
            }
            record.status = "inactive"
            try record.write(to: file)
        } catch {
            if SystemProxyStore.isActive(url, serviceID: snapshot.serviceID) {
                do { try SystemProxyStore.restore(snapshot: snapshot, ownedURL: url) }
                catch { record.detail = "恢复原设置失败：\(error.localizedDescription)" }
            }
            record.status = "error"
            if record.detail == nil { record.detail = error.localizedDescription }
            try? record.write(to: file)
            throw error
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var owner: Int32
    init(ownerPID: Int32) { owner = ownerPID }
    var ownerPID: Int32 { lock.lock(); defer { lock.unlock() }; return owner }
    func adopt(_ pid: Int32) { lock.lock(); owner = pid; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func set() { lock.lock(); stopped = true; lock.unlock() }
}
