import AppKit
import Darwin
import Foundation

public struct NativeProxySession: Codable, Sendable {
    public var helperPID: Int32
    public var ownerPID: Int32
    public let ownerUID: UInt32
    public let controlToken: String
    public let startedAt: Date
    public let proxyHost: String
    public let proxyPort: UInt16
    public let pacURL: URL
    public let snapshot: NetworkProxySnapshot
    public var status: String
    public var detail: String?

    public init(ownerPID: Int32, proxy: ProxySettings, pacURL: URL, snapshot: NetworkProxySnapshot) {
        helperPID = getpid()
        self.ownerPID = ownerPID
        ownerUID = Self.processUID(ownerPID) ?? getuid()
        controlToken = UUID().uuidString + UUID().uuidString
        startedAt = Date()
        proxyHost = proxy.host
        proxyPort = proxy.port
        self.pacURL = pacURL
        self.snapshot = snapshot
        status = "preparing"
    }

    public static var defaultFile: URL {
        file(for: getuid())
    }

    public static func file(for uid: UInt32) -> URL {
        URL(fileURLWithPath: "/Library/Application Support/CodexProxyLauncher/native-proxy-\(uid).json")
    }

    public static func read(from url: URL) throws -> NativeProxySession {
        if url.path.hasPrefix("/Library/Application Support/CodexProxyLauncher/") {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true) else {
                throw NativeProxyError.helperFailed("会话记录不属于受信任的管理员助手")
            }
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if geteuid() == 0 {
            guard url == Self.file(for: ownerUID), ownerUID > 0 else { throw NativeProxyError.helperFailed("拒绝非标准恢复记录路径") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0,
                  !((try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true) else {
                throw NativeProxyError.helperFailed("恢复记录目录权限不安全")
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if geteuid() == 0 {
            guard let entry = getpwuid(ownerUID), let rawName = entry.pointee.pw_name else {
                throw NativeProxyError.helperFailed("无法确认会话用户")
            }
            let accountName = String(cString: rawName)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", "user:\(accountName) allow read", url.path]
            chmod.standardOutput = FileHandle.nullDevice
            chmod.standardError = FileHandle.nullDevice
            try chmod.run()
            chmod.waitUntilExit()
            guard chmod.terminationStatus == 0 else { throw NativeProxyError.helperFailed("无法赋予当前用户读取会话状态的权限") }
        }
    }

    public var isLive: Bool {
        status == "active" && NativeProxySession.processIsAlive(helperPID)
            && SystemProxyStore.isActive(pacURL, serviceID: snapshot.serviceID)
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func processUID(_ pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }
}

@MainActor
public final class NativeProxyClient {
    public static let shared = NativeProxyClient()
    public let stateFile: URL
    public let helperURL: URL

    public init(stateFile: URL = NativeProxySession.defaultFile, helperURL: URL? = nil) {
        self.stateFile = stateFile
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CodexNativeProxy")
    }

    public var session: NativeProxySession? { try? .read(from: stateFile) }

    public func start(proxy: ProxySettings) async throws {
        if let existing = session, existing.isLive {
            guard existing.proxyHost == proxy.host, existing.proxyPort == proxy.port,
                  NativeProxySession.executablePath(existing.helperPID).map({ $0 == helperURL.path }) ?? true else {
                throw NativeProxyError.helperFailed("另一版本的兼容代理仍在运行，请先关闭。")
            }
            try await control(existing, action: "adopt/\(getpid())")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw NativeProxyError.helperUnavailable }
        let command = try authorizationCommand(proxy: proxy)
        let started = Date()
        guard NSWorkspace.shared.open(command) else { throw NativeProxyError.helperFailed("无法打开管理员授权终端") }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let record = session, record.ownerPID == getpid(), record.startedAt >= started {
                if record.isLive { return }
                if record.status == "error" { throw NativeProxyError.helperFailed(record.detail ?? "启动失败") }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw NativeProxyError.helperFailed("管理员授权尚未完成；可在终端完成授权后重新检测")
    }

    public func stop() async throws {
        guard let record = session else { return }
        guard record.isLive else {
            if !NativeProxySession.processIsAlive(record.helperPID),
               SystemProxyStore.isActive(record.pacURL, serviceID: record.snapshot.serviceID) {
                try SystemProxyStore.restore(snapshot: record.snapshot, ownedURL: record.pacURL)
            }
            return
        }
        guard NativeProxySession.executablePath(record.helperPID).map({ $0 == helperURL.path }) ?? true else {
            throw NativeProxyError.helperFailed("助手进程身份不一致，未发送停止信号。")
        }
        try await control(record, action: "stop")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let latest = session, latest.status == "inactive" { return }
            if let latest = session, latest.status == "error" {
                throw NativeProxyError.helperFailed(latest.detail ?? "恢复失败")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NativeProxyError.helperFailed("恢复原系统代理超时；请检查兼容模式状态。")
    }

    public func authorizationCommand(proxy: ProxySettings, ownerPID: Int32? = nil) throws -> URL {
        _ = try NativeProxyPolicy.javaScript(proxy: proxy)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexProxyLauncher")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let command = directory.appendingPathComponent("Enable-Native-Proxy.command")
        let arguments = [helperURL.path, "serve", "--owner-pid", String(ownerPID ?? getpid()), "--state-file", stateFile.path,
                         "--proxy-host", proxy.host, "--proxy-port", String(proxy.port)]
        let log = directory.appendingPathComponent("native-proxy.log")
        let quoted = arguments.map(Self.shellQuote).joined(separator: " ")
        let script = """
        #!/bin/zsh
        set -eu
        umask 077
        print '启用本机 OpenAI 域名兼容代理。退出启动器时恢复原网络设置。'
        print '管理员密码只由 macOS sudo 读取，启动器不会读取或保存密码。'
        /usr/bin/sudo -v
        /usr/bin/sudo -n -b -- \(quoted) >> \(Self.shellQuote(log.path)) 2>&1
        print '授权命令已提交。启动器确认就绪后可关闭此窗口。'
        """
        try Data(script.utf8).write(to: command, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        return command
    }

    public nonisolated static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func control(_ record: NativeProxySession, action: String) async throws {
        var request = URLRequest(url: URL(string: record.pacURL.absoluteString + "/" + action)!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + record.controlToken, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw NativeProxyError.helperFailed("助手未接受控制请求") }
    }
}
