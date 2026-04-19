import Foundation
import Network

/// Tiny localhost HTTP server that waits for a single GET `/callback?code=...&state=...`,
/// replies with a friendly "you can close this tab" page, and resolves the async `start()`
/// call with the captured code + state.
final class ClaudeOAuthCallbackServer {
    struct Result {
        let code: String
        let state: String
    }

    enum ServerError: LocalizedError {
        case alreadyRunning
        case listenerFailed(String)
        case callbackError(String)
        case canceled

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "OAuth callback server already running"
            case let .listenerFailed(msg): return "Callback server failed to start: \(msg)"
            case let .callbackError(msg): return "OAuth callback error: \(msg)"
            case .canceled: return "OAuth flow canceled"
            }
        }
    }

    private let port: UInt16
    private let queue = DispatchQueue(label: "ClaudeOAuthCallbackServer")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Result, Error>?
    private var hasResumed = false

    init(port: UInt16 = ClaudeOAuthConfig.callbackPort) {
        self.port = port
    }

    deinit {
        listener?.cancel()
    }

    /// Starts the listener and waits for the first valid `/callback` request.
    /// Returns the parsed `code` + `state`, or throws on error / cancellation.
    func start() async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { return }
                guard self.listener == nil else {
                    cont.resume(throwing: ServerError.alreadyRunning)
                    return
                }
                self.continuation = cont
                self.hasResumed = false
                self.bootstrapListener()
            }
        }
    }

    /// Cancels the listener and resolves `start()` with a `canceled` error if still waiting.
    func cancel() {
        queue.async { [weak self] in
            self?.resume(.failure(ServerError.canceled))
        }
    }

    // MARK: - Listener

    private func bootstrapListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case let .failed(err):
                    self?.resume(.failure(ServerError.listenerFailed(err.localizedDescription)))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            resume(.failure(ServerError.listenerFailed(error.localizedDescription)))
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                self.respond(on: connection, status: 400, html: Self.html(title: "Error", body: "Failed to read request."))
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                self.respond(on: connection, status: 400, html: Self.html(title: "Error", body: "Empty request."))
                return
            }

            guard let firstLine = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else {
                self.respond(on: connection, status: 400, html: Self.html(title: "Error", body: "Malformed request."))
                return
            }
            let parts = firstLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0] == "GET" else {
                self.respond(on: connection, status: 405, html: Self.html(title: "Method Not Allowed", body: "Only GET is supported."))
                return
            }

            let path = String(parts[1])
            // Ignore noise like /favicon.ico so the real callback still completes.
            guard path.hasPrefix("/callback") else {
                self.respond(on: connection, status: 404, html: Self.html(title: "Not Found", body: "Unknown endpoint."))
                return
            }

            guard let comps = URLComponents(string: "http://localhost\(path)") else {
                self.respond(on: connection, status: 400, html: Self.html(title: "Error", body: "Could not parse callback URL."))
                return
            }
            let items = comps.queryItems ?? []
            let code = items.first { $0.name == "code" }?.value
            let state = items.first { $0.name == "state" }?.value

            if let code, let state {
                self.respond(
                    on: connection,
                    status: 200,
                    html: Self.html(title: "Signed in", body: "You can close this tab and return to Claude Statistics.")
                )
                self.resume(.success(Result(code: code, state: state)))
                return
            }

            let errorDesc = items.first { $0.name == "error_description" }?.value
                ?? items.first { $0.name == "error" }?.value
                ?? "Missing code or state."
            self.respond(on: connection, status: 400, html: Self.html(title: "Login Failed", body: errorDesc))
            self.resume(.failure(ServerError.callbackError(errorDesc)))
        }
    }

    // MARK: - Response helpers

    private func respond(on connection: NWConnection, status: Int, html: String) {
        let body = Data(html.utf8)
        let statusLine: String
        switch status {
        case 200: statusLine = "HTTP/1.1 200 OK"
        case 400: statusLine = "HTTP/1.1 400 Bad Request"
        case 404: statusLine = "HTTP/1.1 404 Not Found"
        case 405: statusLine = "HTTP/1.1 405 Method Not Allowed"
        default: statusLine = "HTTP/1.1 \(status) Error"
        }
        let headers = """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(headers.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resume(_ result: Swift.Result<Result, Error>) {
        guard !hasResumed else { return }
        hasResumed = true
        let cont = continuation
        continuation = nil
        listener?.cancel()
        listener = nil
        switch result {
        case let .success(value): cont?.resume(returning: value)
        case let .failure(err): cont?.resume(throwing: err)
        }
    }

    private static func html(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>\(title) · Claude Statistics</title>
          <style>
            body { font-family: -apple-system, system-ui, sans-serif; background: #f5f5f7; color: #1d1d1f; margin: 0; padding: 80px 24px; text-align: center; }
            .card { max-width: 420px; margin: 0 auto; background: #fff; padding: 40px 32px; border-radius: 16px; box-shadow: 0 6px 24px rgba(0,0,0,0.06); }
            h1 { font-size: 22px; margin: 0 0 12px; font-weight: 600; }
            p { color: #4a4a4f; font-size: 14px; margin: 0; line-height: 1.5; }
          </style>
        </head>
        <body>
          <div class="card">
            <h1>\(title)</h1>
            <p>\(body)</p>
          </div>
        </body>
        </html>
        """
    }
}
