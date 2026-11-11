import Foundation

/// A narrowly scoped system PAC for native helpers that ignore Electron flags.
public enum NativeProxyPolicy {
    public static let domains = [
        "chatgpt.com", "openai.com", "oaistatic.com",
        "oaiusercontent.com", "chatgptusercontent.com"
    ]

    public static func contains(host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { normalized == $0 || normalized.hasSuffix("." + $0) }
    }

    public static func javaScript(proxy: ProxySettings) throws -> String {
        guard ["127.0.0.1", "::1", "localhost"].contains(proxy.host), proxy.port > 0 else {
            throw NativeProxyError.invalidLocalProxy
        }
        let domainsJSON = String(data: try JSONSerialization.data(withJSONObject: domains), encoding: .utf8)!
        let authority = proxy.host == "::1" ? "[::1]:\(proxy.port)" : "\(proxy.host):\(proxy.port)"
        return """
        function FindProxyForURL(url, host) {
            host = host.toLowerCase().replace(/\\.$/, "");
            var domains = \(domainsJSON);
            for (var i = 0; i < domains.length; i++) {
                if (host === domains[i] || dnsDomainIs(host, "." + domains[i])) {
                    return "PROXY \(authority)";
                }
            }
            return "DIRECT";
        }
        """
    }
}

public enum NativeProxyError: LocalizedError {
    case invalidLocalProxy
    case networkServiceUnavailable
    case existingProxy
    case configurationChanged
    case systemConfiguration(String)
    case helperUnavailable
    case helperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocalProxy: return "兼容代理必须使用本机回环地址和有效端口。"
        case .networkServiceUnavailable: return "未找到当前活动网络服务。"
        case .existingProxy: return "当前网络已有系统代理或 PAC，请先保留现有配置并检查冲突。"
        case .configurationChanged: return "网络代理已被其他程序修改；已保留新设置，未覆盖。"
        case .systemConfiguration(let detail): return "无法更新系统代理：\(detail)"
        case .helperUnavailable: return "未找到完整的原生代理助手，请重新安装启动器。"
        case .helperFailed(let detail): return "原生代理助手：\(detail)"
        }
    }
}
