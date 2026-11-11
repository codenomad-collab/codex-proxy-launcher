import CFNetwork
import Foundation

public struct NativeNetworkProbe: Codable, Equatable, Sendable {
    public let statusCode: Int?
    public let elapsedMS: Int
    public let errorCode: Int?
    public var reachable: Bool { statusCode.map { (200...499).contains($0) && $0 != 407 } ?? false }
}

public enum NativeNetworkDiagnostics {
    public static func probe(proxy: ProxySettings? = nil) async -> NativeNetworkProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let proxy {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: Int(proxy.port),
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: Int(proxy.port)
            ]
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = Date()
        let url = URL(string: "https://chatgpt.com/backend-api/aura/site_status?site_url=https%3A%2F%2Fexample.com")!
        do {
            let (_, response) = try await session.data(from: url)
            return NativeNetworkProbe(statusCode: (response as? HTTPURLResponse)?.statusCode,
                                      elapsedMS: Int(Date().timeIntervalSince(start) * 1000), errorCode: nil)
        } catch {
            return NativeNetworkProbe(statusCode: nil, elapsedMS: Int(Date().timeIntervalSince(start) * 1000),
                                      errorCode: (error as NSError).code)
        }
    }
}
