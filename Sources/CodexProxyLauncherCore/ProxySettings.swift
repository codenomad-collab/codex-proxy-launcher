import Foundation

public struct ProxySettings: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = 7890) {
        self.host = host
        self.port = port
    }

    public var displayAddress: String {
        "\(host):\(port)"
    }

    public var httpURL: String {
        "http://\(urlHost):\(port)"
    }

    public var socksURL: String {
        "socks5://\(urlHost):\(port)"
    }

    public var environment: [String: String] {
        [
            "HTTP_PROXY": httpURL,
            "HTTPS_PROXY": httpURL,
            "ALL_PROXY": socksURL,
            "NO_PROXY": "localhost,127.0.0.1,::1",
            "http_proxy": httpURL,
            "https_proxy": httpURL,
            "all_proxy": socksURL,
            "no_proxy": "localhost,127.0.0.1,::1",
            // Node's built-in fetch and Electron's utility processes do not
            // consistently consult proxy environment variables unless these
            // opt-ins are present.
            "NODE_USE_ENV_PROXY": "1",
            "ELECTRON_GET_USE_PROXY": "1"
        ]
    }

    public var electronArguments: [String] {
        [
            "--proxy-server=\(httpURL)",
            "--proxy-bypass-list=localhost;127.0.0.1;[::1]"
        ]
    }

    private var urlHost: String {
        if host.contains(":"), !host.hasPrefix("[") {
            return "[\(host)]"
        }
        return host
    }
}
