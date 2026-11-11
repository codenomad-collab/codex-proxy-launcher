import Foundation
import Network

public final class LoopbackPACServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.codex-proxy-launcher.pac")
    private var listener: NWListener?
    private let path = "/codex-\(UUID().uuidString.lowercased()).pac"
    private let script: String
    public var controlHandler: (@Sendable (String, String) -> Bool)?

    public init(proxy: ProxySettings) throws { script = try NativeProxyPolicy.javaScript(proxy: proxy) }

    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.receive(connection, accumulated: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = StartCompletion(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = listener.port else { return }
                    completion.finish(.success(URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)")!))
                case .failed(let error): completion.finish(.failure(error))
                case .cancelled: completion.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener?.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        if connection.state == .setup {
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            guard request.count <= 16_384 else { self.respond(connection, status: "431 Request Header Fields Too Large"); return }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                let fields = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                if fields.count == 3, fields[0] == "POST", fields[1].hasPrefix(self.path + "/") {
                    let authorization = text.components(separatedBy: "\r\n").first {
                        $0.lowercased().hasPrefix("authorization: ")
                    }.map { String($0.dropFirst("authorization: ".count)) } ?? ""
                    let action = String(fields[1].dropFirst(self.path.count + 1))
                    let accepted = self.controlHandler?(action, authorization) == true
                    self.respond(connection, status: accepted ? "204 No Content" : "403 Forbidden")
                    return
                }
                guard fields.count == 3, ["GET", "HEAD"].contains(String(fields[0])) else {
                    self.respond(connection, status: "405 Method Not Allowed"); return
                }
                guard fields[1] == Substring(self.path) else { self.respond(connection, status: "404 Not Found"); return }
                self.respond(connection, status: "200 OK", headOnly: fields[0] == "HEAD", body: self.script)
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, accumulated: request) }
        }
    }

    private func respond(_ connection: NWConnection, status: String, headOnly: Bool = false, body: String = "") {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + (headOnly ? "" : body)
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class StartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
