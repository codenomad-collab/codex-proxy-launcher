import Foundation
import SystemConfiguration

public struct NetworkProxySnapshot: Codable, Equatable, Sendable {
    public let serviceID: String
    public let serviceName: String
    public let configuration: Data

    public init(serviceID: String, serviceName: String, dictionary: [String: Any]) throws {
        self.serviceID = serviceID
        self.serviceName = serviceName
        configuration = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    public var dictionary: [String: Any] {
        (try? PropertyListSerialization.propertyList(from: configuration, format: nil)) as? [String: Any] ?? [:]
    }
}

public enum SystemProxyStore {
    private static let pacEnabled = kSCPropNetProxiesProxyAutoConfigEnable as String
    private static let pacURL = kSCPropNetProxiesProxyAutoConfigURLString as String

    public static func capture(serviceID: String? = nil) throws -> NetworkProxySnapshot {
        guard let preferences = SCPreferencesCreate(nil, "CodexProxyLauncher" as CFString, nil) else { throw failure() }
        let id: String
        if let serviceID { id = serviceID }
        else {
            guard let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
                  let active = state["PrimaryService"] as? String else { throw NativeProxyError.networkServiceUnavailable }
            id = active
        }
        guard let service = SCNetworkServiceCopy(preferences, id as CFString),
              let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            throw NativeProxyError.networkServiceUnavailable
        }
        return try NetworkProxySnapshot(
            serviceID: id,
            serviceName: (SCNetworkServiceGetName(service) as String?) ?? id,
            dictionary: (SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any]) ?? [:]
        )
    }

    public static func installingPAC(_ url: URL, into original: [String: Any]) throws -> [String: Any] {
        let enabledKeys = [pacEnabled, "HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoDiscoveryEnable"]
        guard !enabledKeys.contains(where: { (original[$0] as? NSNumber)?.boolValue == true }) else {
            throw NativeProxyError.existingProxy
        }
        var updated = original
        updated[pacEnabled] = 1
        updated[pacURL] = url.absoluteString
        return updated
    }

    /// Restore only our PAC fields. Keep unrelated changes and never take over another PAC.
    public static func restoring(_ original: [String: Any], current: [String: Any], ownedURL: URL) throws -> [String: Any] {
        guard current[pacURL] as? String == ownedURL.absoluteString else {
            throw NativeProxyError.configurationChanged
        }
        var restored = current
        for key in [pacEnabled, pacURL] {
            if let value = original[key] { restored[key] = value }
            else { restored.removeValue(forKey: key) }
        }
        return restored
    }

    public static func install(url: URL, snapshot: NetworkProxySnapshot) throws {
        try update(serviceID: snapshot.serviceID) { current in
            guard NSDictionary(dictionary: current).isEqual(to: snapshot.dictionary) else {
                throw NativeProxyError.configurationChanged
            }
            return try installingPAC(url, into: current)
        }
    }

    public static func restore(snapshot: NetworkProxySnapshot, ownedURL: URL) throws {
        try update(serviceID: snapshot.serviceID) {
            try restoring(snapshot.dictionary, current: $0, ownedURL: ownedURL)
        }
    }

    public static func isActive(_ url: URL, serviceID: String) -> Bool {
        guard let current = try? capture(serviceID: serviceID).dictionary else { return false }
        return current[pacURL] as? String == url.absoluteString && (current[pacEnabled] as? NSNumber)?.boolValue == true
    }

    private static func update(serviceID: String, transform: ([String: Any]) throws -> [String: Any]) throws {
        guard let preferences = SCPreferencesCreate(nil, "CodexProxyLauncher" as CFString, nil),
              SCPreferencesLock(preferences, true) else { throw failure() }
        defer { SCPreferencesUnlock(preferences) }
        guard let service = SCNetworkServiceCopy(preferences, serviceID as CFString),
              let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            throw NativeProxyError.networkServiceUnavailable
        }
        let current = (SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any]) ?? [:]
        let updated = try transform(current)
        guard SCNetworkProtocolSetConfiguration(protocolRef, updated as CFDictionary),
              SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else { throw failure() }
    }

    private static func failure() -> NativeProxyError {
        .systemConfiguration(String(cString: SCErrorString(SCError())))
    }
}
