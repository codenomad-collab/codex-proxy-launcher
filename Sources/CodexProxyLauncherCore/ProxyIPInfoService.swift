import CFNetwork
import Foundation

public struct ProxyIPInfo: Equatable, Sendable {
    public let ip: String
    public let addressType: String
    public let continent: String
    public let country: String
    public let countryCode: String
    public let region: String
    public let city: String
    public let latitude: Double?
    public let longitude: Double?
    public let asn: Int?
    public let organization: String
    public let isp: String
    public let domain: String
    public let timezone: String
    public let timezoneAbbreviation: String

    public var locationSummary: String {
        [city, region, country]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    public var networkSummary: String {
        let organizationName = !isp.isEmpty ? isp : organization
        if let asn, !organizationName.isEmpty {
            return "AS\(asn) · \(organizationName)"
        }
        if let asn {
            return "AS\(asn)"
        }
        return organizationName
    }

    public var countryFlag: String {
        countryCode.uppercased().unicodeScalars.compactMap { scalar in
            UnicodeScalar(127_397 + scalar.value).map(String.init)
        }.joined()
    }
}

public enum ProxyIPInfoError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case serviceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "IP 信息服务地址无效。"
        case .invalidResponse:
            return "IP 信息服务返回了无法识别的数据。"
        case .serviceFailure(let message):
            return "IP 信息查询失败：\(message)"
        }
    }
}

public enum ProxyIPInfoService {
    public static func fetch(proxy: ProxySettings) async throws -> ProxyIPInfo {
        var components = URLComponents(string: "https://ipwho.is/")
        components?.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "success,message,ip,type,continent,country,country_code,region,city,latitude,longitude,connection,timezone"
            )
        ]
        guard let url = components?.url else {
            throw ProxyIPInfoError.invalidEndpoint
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: proxy.host,
            kCFNetworkProxiesHTTPPort as String: Int(proxy.port),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: proxy.host,
            kCFNetworkProxiesHTTPSPort as String: Int(proxy.port)
        ]

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ProxyIPInfoError.invalidResponse
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> ProxyIPInfo {
        let response = try JSONDecoder().decode(IPWhoResponse.self, from: data)
        guard response.success else {
            throw ProxyIPInfoError.serviceFailure(
                response.message ?? "服务未说明原因"
            )
        }
        guard let ip = response.ip, !ip.isEmpty else {
            throw ProxyIPInfoError.invalidResponse
        }

        return ProxyIPInfo(
            ip: ip,
            addressType: response.type ?? "",
            continent: response.continent ?? "",
            country: response.country ?? "",
            countryCode: response.countryCode ?? "",
            region: response.region ?? "",
            city: response.city ?? "",
            latitude: response.latitude,
            longitude: response.longitude,
            asn: response.connection?.asn,
            organization: response.connection?.org ?? "",
            isp: response.connection?.isp ?? "",
            domain: response.connection?.domain ?? "",
            timezone: response.timezone?.id ?? "",
            timezoneAbbreviation: response.timezone?.abbr ?? ""
        )
    }
}

private struct IPWhoResponse: Decodable {
    let success: Bool
    let message: String?
    let ip: String?
    let type: String?
    let continent: String?
    let country: String?
    let countryCode: String?
    let region: String?
    let city: String?
    let latitude: Double?
    let longitude: Double?
    let connection: Connection?
    let timezone: Timezone?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case ip
        case type
        case continent
        case country
        case countryCode = "country_code"
        case region
        case city
        case latitude
        case longitude
        case connection
        case timezone
    }

    struct Connection: Decodable {
        let asn: Int?
        let org: String?
        let isp: String?
        let domain: String?
    }

    struct Timezone: Decodable {
        let id: String?
        let abbr: String?
    }
}
