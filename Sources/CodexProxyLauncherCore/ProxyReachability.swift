import Foundation
import Network

public enum ProxyReachability {
    public static func check(
        settings: ProxySettings,
        timeout: TimeInterval = 1.5
    ) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: settings.port) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(settings.host),
                port: port,
                using: .tcp
            )
            let completion = OneShotCompletion(
                connection: connection,
                continuation: continuation
            )
            let queue = DispatchQueue(label: "local.codex-proxy-launcher.reachability")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(false)
            }
        }
    }
}

private final class OneShotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        guard let pending else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: result)
    }
}
