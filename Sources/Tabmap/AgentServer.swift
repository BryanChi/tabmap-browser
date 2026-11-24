import Foundation
import Network
import TabMapCore

/// The local MCP server Claude connects to ("Streamable HTTP" transport, JSON responses only).
/// Listens on 127.0.0.1 only, and every request needs the bearer token from Settings.
/// Tool calls are handed to `AgentTools` on the main actor.
final class AgentServer: @unchecked Sendable {
    static let shared = AgentServer()

    private let queue = DispatchQueue(label: "tabmap.agent-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var token = ""
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start(port: UInt16, token: String, status: @escaping (String) -> Void) {
        setToken(token)
        queue.async { [self] in
            guard listener == nil else { status("Listening on 127.0.0.1:\(port)"); return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                // Loopback only: nothing on the network can reach it.
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: status("Listening on 127.0.0.1:\(port)")
                    case .failed(let error): status("Could not listen on port \(port): \(error.localizedDescription)")
                    case .cancelled: status("Off")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                status("Could not start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func setToken(_ token: String) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    private var currentToken: String {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.connections[key] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel(); return }
                self.receive(on: connection, buffer: buffer)
            case .invalid(let reason):
                self.send(HTTPResponse.encode(status: 400, reason: "Bad Request", body: Data(reason.utf8)),
                          on: connection, close: true)
            case .request(let request, let consumed):
                let rest = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
                self.handle(request) { response in
                    self.send(response, on: connection, close: false)
                    self.queue.async {
                        if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: rest) }
                    }
                }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection, close: Bool) {
        connection.send(content: data, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    // MARK: HTTP

    private func handle(_ request: HTTPRequest, reply: @escaping (Data) -> Void) {
        switch AgentAccess.check(request, token: currentToken) {
        case .allowed: break
        case .unauthorized:
            reply(HTTPResponse.encode(status: 401, reason: "Unauthorized",
                                      headers: ["WWW-Authenticate": "Bearer"],
                                      body: Data("Tabmap needs the key from Settings > Let Claude control Tabmap.".utf8)))
            return
        case .forbidden(let why):
            reply(HTTPResponse.encode(status: 403, reason: "Forbidden", body: Data(why.utf8)))
            return
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp" || path == "/mcp/" else {
            reply(HTTPResponse.encode(status: 404, reason: "Not Found"))
            return
        }
        switch request.method {
        case "POST":
            break
        case "DELETE":
            reply(HTTPResponse.encode(status: 200, reason: "OK"))
            return
        default:
            // No server-to-client stream: every answer comes back in the POST's response.
            reply(HTTPResponse.encode(status: 405, reason: "Method Not Allowed", headers: ["Allow": "POST, DELETE"]))
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            reply(jsonResponse(AgentMCP.error(id: NSNull(), code: -32700, message: "Parse error")))
            return
        }
        let isBatch: Bool
        if json is [[String: Any]] {
            isBatch = true
        } else if json is [String: Any] {
            isBatch = false
        } else {
            reply(jsonResponse(AgentMCP.error(id: NSNull(), code: -32600, message: "Invalid Request")))
            return
        }
        // The JSON objects are not Sendable; hand them across as bytes.
        let body = request.body
        Task { @MainActor in
            let parsed = (try? JSONSerialization.jsonObject(with: body))
            let list: [[String: Any]] = isBatch ? (parsed as? [[String: Any]] ?? []) : [(parsed as? [String: Any]) ?? [:]]
            var answers: [[String: Any]] = []
            for message in list {
                if let answer = await AgentMCP.handle(message) { answers.append(answer) }
            }
            let data: Data
            if answers.isEmpty {
                data = HTTPResponse.encode(status: 202, reason: "Accepted")
            } else {
                let object: Any = isBatch ? answers : answers[0]
                data = Self.encodeJSON(object)
            }
            reply(data)
        }
    }

    private func jsonResponse(_ object: [String: Any]) -> Data {
        Self.encodeJSON(object)
    }

    static func encodeJSON(_ object: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse.encode(status: 200, reason: "OK", headers: ["Content-Type": "application/json"], body: body)
    }
}

/// JSON-RPC for MCP: initialize, tools/list, tools/call, ping.
@MainActor
enum AgentMCP {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    You are controlling Tabmap, the user's own web browser on their Mac, in their normal signed-in session. \
    Your clicks and typing arrive as real mouse and keyboard input, and the user watches your pointer. \
    Start with read_page (numbered elements you can click or type into); take a screenshot only when the layout matters. \
    open_url opens pages in your own row of the tab map. With background true the tab stays out of sight, so the user \
    can keep using Tabmap, and you can work in several such tabs at once by passing each one's id as `tab` \
    (calls for different background tabs run side by side). Prefer background tabs unless the user wants to watch. \
    Every action waits for the page to load and settle before it returns, so you rarely need wait_for. \
    Ask the user before buying or paying for anything, sending messages, emails or posts, deleting things, \
    changing account or security settings, or accepting terms. \
    You never see or type passwords: when a sign-in needs one, the user is asked to do it. \
    If a tool says a human check (CAPTCHA) or a question from the page needs the user, do not try to get past it: \
    call wait_for_user and carry on once it returns. \
    If a tool says the user stopped you, stop and ask them before doing anything else in the browser.
    """

    static func handle(_ message: [String: Any]) async -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response from the client to something we never asked: ignore.
            return nil
        }
        // Notifications (no id) get no answer.
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? supportedVersions[0]
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            return result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]] as [String: Any],
                "serverInfo": ["name": "tabmap", "title": "Tabmap browser", "version": "0.2.0"],
                "instructions": instructions,
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": AgentTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let outcome = await AgentTools.shared.call(name, arguments)
            return result(id: id, ["content": outcome.content, "isError": outcome.isError])
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    nonisolated static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]]
    }
}
