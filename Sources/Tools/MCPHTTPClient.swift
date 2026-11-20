//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// MCPHTTPClient.swift
//

import Foundation
import Logger
import Stores

/// A live connection to one MCP server declared by the ACP client for a
/// session. Both transport flavors — a spawned stdio process and a remote
/// HTTP endpoint — implement it, so the ACP server can register, use, and
/// tear down connections uniformly.
public protocol MCPClientHandle: ToolProvider {
    /// Runs the MCP handshake (initialize → notifications/initialized).
    func start() async throws

    /// Fetches every tool the server advertises (tools/list), unfiltered
    /// by the policy allowlist.
    @discardableResult
    func fetchTools() async -> [ToolDefinition]

    /// Every tool name the server advertises, unfiltered by the policy
    /// allowlist — for internal routing (e.g. read_file → XcodeRead),
    /// which must reach tools the model is not offered directly.
    func advertisedToolNames() async -> [String]

    /// Executes one tool (tools/call) and returns the text of its result
    /// without emitting any session/update tool-call notifications. For
    /// internal round-trips that should stay invisible in the client UI
    /// (e.g. read_file calling the IDE's XcodeRead); the caller emits
    /// updates under its own tool name.
    func callTool(name: String, argsJSON: String) async -> String

    /// Closes the connection and releases its resources.
    func stop() async
}

/// Failure to connect to a remote (HTTP) MCP server.
public enum MCPHTTPClientError: Error, CustomStringConvertible {
    /// The descriptor carries no usable URL (or the URL is malformed).
    case invalidURL

    public var description: String {
        switch self {
        case .invalidURL:
            return "MCP server has no valid URL"
        }
    }
}

/// A client for one remote MCP server declared by the ACP client, speaking
/// the two MCP HTTP transports:
///
/// - `type: "http"` — Streamable HTTP (spec 2025-03-26): every JSON-RPC
///   message is its own POST; the response is either a single JSON document
///   or an SSE stream, and the negotiated `Mcp-Session-Id` header is
///   replayed on every subsequent request.
/// - `type: "sse"` — the legacy HTTP+SSE transport (spec 2024-11-05): a
///   long-lived GET event stream whose first `endpoint` event names the URL
///   to POST messages to, and which carries every server message.
///
/// As with the stdio client, every read is deadline-bounded so a server
/// that never answers can never wedge the ACP loop, and server-to-client
/// requests are answered with an empty result so the server never blocks
/// on us.
public actor MCPHTTPClient: MCPClientHandle {
    /// Which MCP HTTP transport the server speaks.
    private enum Kind: Sendable {
        case streamable  // "http": one POST per message
        case sse         // "sse":  persistent event stream + POST endpoint
        case unsupported
    }

    /// Handshake reads (initialize, tools/list) give up after this long.
    private let handshakeTimeout: TimeInterval
    /// Tool calls may run long IDE operations (builds, tests).
    private let toolCallTimeout: TimeInterval

    private let descriptor: MCPServerDescriptor
    private let kind: Kind
    private let logger: Loggable
    private let debugLog: Bool
    /// The connected client's policy for this server's tools (allowlist +
    /// presentation).
    private let policy: MCPToolPolicy
    /// The server's statement about the model's vision support (nil when it
    /// does not report it); gates the policy's vision-required tools in
    /// definitions().
    private let supportsVision: Bool?
    private let session: URLSession

    private var url: URL?
    /// Mcp-Session-Id returned by the server at initialization (Streamable
    /// HTTP). Replayed on every subsequent request.
    private var serverSessionID: String?
    /// POST endpoint named by the first `endpoint` event (legacy SSE).
    private var sseEndpoint: URL?
    /// The long-lived reader for the legacy SSE stream.
    private var ssePump: Task<Void, Never>?
    private var tools: [ToolDefinition] = []
    private var nextRequestId = 1000
    private var started = false
    /// True once the server answered `initialize` with a result. Gates
    /// tools/list so a dead server is never waited out a second time.
    private var handshakeSucceeded = false
    /// Waiters for in-flight request responses (the raw JSON bytes of the
    /// response message), keyed by request id.
    private var pending: [Int: CheckedContinuation<Data?, Never>] = [:]
    /// Resumed when the legacy SSE endpoint event arrives (or the deadline
    /// elapses).
    private var endpointWaiter: CheckedContinuation<URL?, Never>?

    /// Creates the client without connecting. `start()` opens the
    /// connection and runs the handshake.
    public init(
        descriptor: MCPServerDescriptor,
        logger: Loggable,
        debugLog: Bool = false,
        policy: MCPToolPolicy = .unrestricted,
        supportsVision: Bool? = nil,
        handshakeTimeout: TimeInterval = 10,
        toolCallTimeout: TimeInterval = 600
    ) {
        self.descriptor = descriptor
        self.logger = logger
        self.debugLog = debugLog
        self.policy = policy
        self.supportsVision = supportsVision
        self.handshakeTimeout = handshakeTimeout
        self.toolCallTimeout = toolCallTimeout

        switch descriptor.transport {
        case .http:
            self.kind = .streamable
        case .sse:
            self.kind = .sse
        case .stdio:
            self.kind = .unsupported
        }

        let configuration = URLSessionConfiguration.ephemeral
        // Long IDE operations can run for many minutes without traffic; the
        // per-request deadlines below are idle bounds, not total bounds.
        configuration.timeoutIntervalForRequest = max(60, toolCallTimeout)
        configuration.timeoutIntervalForResource = max(60, toolCallTimeout)
        self.session = URLSession(configuration: configuration)
    }

    /// True once `start()` has opened the connection (even if the server
    /// never answered — a dead server simply yields no tools).
    public var isStarted: Bool {
        started
    }

    /// The server name this client represents.
    public var serverName: String {
        descriptor.name
    }

    /// The tools offered to the model: the advertised tools narrowed by
    /// the policy allowlist (and by the policy's vision-required set when
    /// the model does not support vision).
    public func definitions() async -> [ToolDefinition] {
        tools.filter { policy.isAllowed($0.function.name, supportsVision: supportsVision) }
    }

    /// Every tool name the server advertises, unfiltered by the allowlist.
    public func advertisedToolNames() async -> [String] {
        tools.map { $0.function.name }
    }

    // MARK: - MCPClientHandle

    /// Opens the connection and runs the MCP handshake
    /// (initialize → notifications/initialized). A server that starts but
    /// never answers yields no tools: the initialized notification is
    /// skipped and fetchTools() short-circuits instead of waiting out
    /// another timeout. Only an unusable URL throws.
    public func start() async throws {
        guard
            kind != .unsupported,
            let rawURL = descriptor.url,
            let endpoint = URL(string: rawURL)
        else {
            throw MCPHTTPClientError.invalidURL
        }
        self.url = endpoint
        started = true

        if kind == .sse {
            // The legacy transport names its POST endpoint in the first
            // event of the stream, so the stream must be open before
            // initialize.
            await openSSEStream()
            guard await waitForEndpoint(timeout: handshakeTimeout) != nil else {
                logger.debug("MCP server '\(descriptor.name)': no endpoint event on the SSE stream")
                return
            }
        }

        // Step 1 of the MCP handshake. The server's response carries the
        // negotiated protocol version; we do not act on it.
        let initResponse = await request(
            "initialize",
            params: [
                "protocolVersion": kind == .streamable ? "2025-03-26" : "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "Terrapin", "version": "1.0.0"],
            ],
            timeout: handshakeTimeout
        )
        handshakeSucceeded = initResponse?["result"] != nil
        if !handshakeSucceeded {
            logger.debug("MCP server '\(descriptor.name)': no response to initialize")
            return
        }

        // Step 2: the mandatory initialized notification.
        await notify("notifications/initialized")
    }

    /// Fetches every tool the server advertises (tools/list), unfiltered
    /// by the policy allowlist (see definitions() and advertisedToolNames()).
    @discardableResult
    public func fetchTools() async -> [ToolDefinition] {
        // The server never completed the handshake, so a tools/list request
        // would only wait out the full handshake timeout again. Fail fast
        // with no tools.
        guard handshakeSucceeded else { return [] }

        guard
            let response = await request("tools/list", timeout: handshakeTimeout),
            let result = response["result"] as? [String: Any],
            let toolsArray = result["tools"] as? [[String: Any]]
        else {
            return []
        }

        var definitions: [ToolDefinition] = []
        for toolDict in toolsArray {
            guard
                let name = toolDict["name"] as? String,
                let inputSchema = toolDict["inputSchema"] as? [String: Any],
                let schemaData = try? JSONSerialization.data(withJSONObject: inputSchema),
                let parameters = try? JSONDecoder().decode(
                    [String: AnySendable].self,
                    from: schemaData
                )
            else { continue }
            definitions.append(
                ToolDefinition(
                    function: FunctionDefinition(
                        name: name,
                        description: toolDict["description"] as? String ?? "",
                        parameters: parameters
                    )
                )
            )
        }

        self.tools = definitions
        return definitions
    }

    /// Closes the MCP session and releases the connection.
    public func stop() async {
        if kind == .streamable, let url {
            // DELETE explicitly terminates the session on the server (best
            // effort; some servers answer 405).
            var request = makeRequest(url: url, method: "DELETE")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            _ = try? await session.data(for: request)
        }
        ssePump?.cancel()
        ssePump = nil
        flushPending()
        started = false
    }

    // MARK: - ToolProvider

    /// Executes one MCP tool (tools/call) and reports progress through
    /// `sendJSON`, mirroring the stdio client's session updates.
    public func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: ([String: Any]) -> Void
    ) async -> ToolResult {
        let callId = "call_" + UUID().uuidString
        let category = policy.category(for: name)
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "name": name,
                    "title": category.title,
                    "kind": category.kind,
                    "status": "in_progress"
                ]
            ]
        ])

        let (text, image, isFailure) = await performToolCall(name: name, argsJSON: argsJSON)
        if debugLog {
            Self.appendDebugLog(server: descriptor.name, name: name, argsJSON: argsJSON, result: text)
        }

        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": callId,
                    "status": isFailure ? "failed" : "completed"
                ]
            ]
        ])

        return ToolResult(text: text, image: image)
    }

    // MARK: - Tool Calls

    /// One invisible tools/call round-trip: the raw text result, with a
    /// failure prefix when the call did not succeed.
    public func callTool(name: String, argsJSON: String) async -> String {
        let (text, _, isFailure) = await performToolCall(name: name, argsJSON: argsJSON)
        guard isFailure else { return text }
        return text.hasPrefix("Error") ? text : "Error: \(text)"
    }

    /// Runs one tool (tools/call) and decodes its content. The response is
    /// JSON-RPC `result`-shaped (content is an array of typed parts); an
    /// isError flag or a JSON-RPC error object marks a failure.
    private func performToolCall(name: String, argsJSON: String)
        async -> (text: String, image: ImageAttachment?, isFailure: Bool)
    {
        let argsDict: [String: Any] =
            (try? JSONSerialization.jsonObject(
                with: argsJSON.data(using: .utf8) ?? Data()
            ) as? [String: Any]) ?? [:]

        guard
            let response = await request(
                "tools/call",
                params: [
                    "name": name,
                    "arguments": argsDict,
                ],
                timeout: toolCallTimeout
            )
        else {
            return ("Error: No response from MCP server '\(descriptor.name)'", nil, true)
        }

        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? Self.jsonString(error)
            return ("Error executing tool '\(name)': \(message)", nil, true)
        }

        guard let result = response["result"] as? [String: Any] else {
            return ("Error: Invalid content returned by tool '\(name)'", nil, true)
        }

        var textLines: [String] = []
        var image: ImageAttachment?
        if let content = result["content"] as? [[String: Any]] {
            for entry in content {
                switch entry["type"] as? String {
                case "text":
                    if let text = entry["text"] as? String {
                        textLines.append(text)
                    }
                case "image":
                    // MCP image content: base64 data + mimeType. Attach the
                    // first one so a vision model can see it.
                    if image == nil,
                       let data = entry["data"] as? String,
                       let mimeType = entry["mimeType"] as? String
                    {
                        image = ImageAttachment(
                            mimeType: mimeType,
                            base64: data,
                            source: "mcp:\(descriptor.name)"
                        )
                    }
                default:
                    break
                }
            }
        }

        var text = textLines.joined(separator: "\n")
        if text.isEmpty, let structured = result["structuredContent"] {
            text = Self.jsonString(structured)
        }
        if text.isEmpty, image == nil {
            return ("Error: Invalid content returned by tool '\(name)'", nil, true)
        }

        let isFailure = (result["isError"] as? Bool) == true
        return (text, image, isFailure)
    }

    // MARK: - JSON-RPC

    /// Sends a request and returns the response matching its id, or nil on
    /// timeout or failure. Server-to-client requests are answered with an
    /// empty result so the server never blocks on us.
    private func request(
        _ method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval
    ) async -> [String: Any]? {
        let id = nextID()
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            message["params"] = params
        }
        guard
            let body = try? JSONSerialization.data(
                withJSONObject: message,
                options: [.withoutEscapingSlashes]
            )
        else {
            return nil
        }

        // The waiter must be registered before the message is sent, so no
        // response can arrive without a continuation for it. The closure of
        // withCheckedContinuation runs synchronously, so registering the
        // waiter and spawning the sender inside it preserves that order.
        // The deadline bounds how long we wait (the answer may arrive long
        // after the transport gave up: stream cut, slow server).
        let responseData = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expirePending(id: id)
            }
            Task { [weak self] in
                await self?.deliver(body, timeout: timeout)
            }
        }
        pending[id] = nil
        guard
            let data = responseData,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Delivers a serialized message; the response either rides the POST
    /// response (Streamable HTTP) or the persistent event stream (legacy
    /// SSE).
    private func deliver(_ body: Data, timeout: TimeInterval) async {
        switch kind {
        case .streamable:
            await postStreamable(body, timeout: timeout)
        case .sse:
            if let endpoint = sseEndpoint {
                await postToSSEEndpoint(body, endpoint)
            }
        case .unsupported:
            break
        }
    }

    /// Sends a notification (no id, no response expected).
    private func notify(_ method: String) async {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        guard
            let body = try? JSONSerialization.data(
                withJSONObject: message,
                options: [.withoutEscapingSlashes]
            )
        else { return }
        await deliver(body, timeout: handshakeTimeout)
    }

    /// Routes one inbound JSON-RPC message: server-to-client requests are
    /// answered with an empty result (same policy as the stdio client),
    /// responses resume their waiting request, and notifications are
    /// skipped. A batch array yields its first message.
    private func dispatchInbound(_ data: Data) async {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return }
        let message: [String: Any]
        if let single = parsed as? [String: Any] {
            message = single
        } else if let batch = parsed as? [[String: Any]] {
            guard let first = batch.first else { return }
            message = first
        } else {
            return
        }

        if let method = message["method"] as? String {
            if let requestID = message["id"] {
                logger.debug(
                    "MCP '\(descriptor.name)': answering server request '\(method)' with an empty result"
                )
                await answerServerRequest(id: requestID)
            }
            return
        }
        if let id = message["id"] as? Int,
           let continuation = pending.removeValue(forKey: id)
        {
            guard let messageData = try? JSONSerialization.data(withJSONObject: message) else { return }
            continuation.resume(returning: messageData)
        }
    }

    /// Answers a server-to-client request with an empty result.
    private func answerServerRequest(id: Any) async {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ]
        guard
            let body = try? JSONSerialization.data(
                withJSONObject: response,
                options: [.withoutEscapingSlashes]
            )
        else { return }
        await deliver(body, timeout: handshakeTimeout)
    }

    private func nextID() -> Int {
        nextRequestId += 1
        return nextRequestId
    }

    private func expirePending(id: Int) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: nil)
        }
    }

    private func flushPending() {
        for (_, continuation) in pending {
            continuation.resume(returning: nil)
        }
        pending.removeAll(keepingCapacity: false)
    }

    // MARK: - Streamable HTTP Transport

    /// POSTs one serialized JSON-RPC message to the MCP endpoint and
    /// drains the full response — a single JSON document or an SSE stream
    /// (spec 2025-03-26). Inbound messages are dispatched for
    /// correlation; the read is deadline-bounded so a server that streams
    /// forever cannot wedge the call.
    private func postStreamable(_ body: Data, timeout: TimeInterval) async {
        guard let url else { return }

        var httpRequest = makeRequest(url: url, method: "POST")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        httpRequest.httpBody = body

        do {
            let (bytes, response) = try await session.bytes(for: httpRequest)
            captureSessionID(from: response)
            guard let http = response as? HTTPURLResponse else { return }
            let contentType = (http.value(forHTTPHeaderField: "content-type") ?? "").lowercased()

            if http.statusCode == 200, contentType.contains("text/event-stream") {
                await readSSEEvents(bytes, deadline: Date().addingTimeInterval(timeout))
            } else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                }
                await dispatchResponseBody(data, status: http.statusCode)
            }
        } catch {
            logger.debug("MCP '\(descriptor.name)': request failed: \(error)")
        }
    }

    /// A non-stream POST response: a single JSON-RPC message, a JSON-RPC
    /// batch array, or — on 4xx — often a JSON-RPC error object in the
    /// body.
    private func dispatchResponseBody(_ data: Data, status: Int) async {
        guard !data.isEmpty else { return }
        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            if status >= 400 {
                let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? "<binary>"
                logger.debug("MCP '\(descriptor.name)': HTTP \(status) with non-JSON body: \(body.prefix(300))")
            }
            return
        }
        await dispatchInbound(data)
    }

    /// Captures the Mcp-Session-Id the server assigns at initialization;
    /// every subsequent request must replay it.
    private func captureSessionID(from response: URLResponse) {
        guard
            let http = response as? HTTPURLResponse,
            let value = http.value(forHTTPHeaderField: "Mcp-Session-Id"),
            !value.isEmpty
        else { return }
        serverSessionID = value
    }

    // MARK: - Legacy HTTP+SSE Transport

    /// Opens the long-lived GET event stream of the legacy SSE transport.
    /// The server sends an `endpoint` event first, then carries every
    /// server message for the lifetime of the session.
    private func openSSEStream() async {
        guard let url else { return }
        var request = makeRequest(url: url, method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  (http.value(forHTTPHeaderField: "content-type") ?? "").contains("text/event-stream")
            else {
                logger.debug("MCP '\(descriptor.name)': SSE stream open refused")
                return
            }
            ssePump = Task { [weak self] in
                await self?.readSSEEvents(bytes, deadline: nil)
            }
        } catch {
            logger.debug("MCP '\(descriptor.name)': SSE stream open failed: \(error)")
        }
    }

    /// POSTs a serialized message to the legacy SSE transport's message
    /// endpoint. The server acknowledges with an empty 202; the actual
    /// response arrives on the event stream.
    private func postToSSEEndpoint(_ body: Data, _ endpoint: URL) async {
        var request = makeRequest(url: endpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode)
            {
                logger.debug("MCP '\(descriptor.name)': POST to the SSE endpoint returned \(http.statusCode)")
            }
        } catch {
            logger.debug("MCP '\(descriptor.name)': POST to the SSE endpoint failed: \(error)")
        }
    }

    /// Waits for the first `endpoint` event of the legacy SSE stream (the
    /// URI to POST messages to), or nil when the deadline elapses.
    private func waitForEndpoint(timeout: TimeInterval) async -> URL? {
        if let endpoint = sseEndpoint {
            return endpoint
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            endpointWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expireEndpointWaiter()
            }
        }
    }

    private func expireEndpointWaiter() {
        if let waiter = endpointWaiter {
            endpointWaiter = nil
            waiter.resume(returning: sseEndpoint)
        }
    }

    // MARK: - SSE Parsing

    /// Parses SSE events from `bytes` and dispatches each one. When a
    /// deadline is given (a Streamable HTTP POST response), the read stops
    /// at the deadline instead of waiting for the server to close the
    /// stream.
    private func readSSEEvents(_ bytes: URLSession.AsyncBytes, deadline: Date?) async {
        // Lines are split manually from raw chunks: AsyncBytes.lines drops
        // blank lines, and the blank line is what delimits SSE events.
        var eventName = ""
        var dataLines: [String] = []
        var buffer = Data()

        do {
            for try await chunk in bytes {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    var lineData = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let last = lineData.last, last == 0x0D {
                        lineData.removeLast()
                    }
                    let line = String(decoding: lineData, as: UTF8.self)
                    if line.isEmpty {
                        // A blank line dispatches the buffered event.
                        guard !eventName.isEmpty || !dataLines.isEmpty else { continue }
                        let name = eventName.isEmpty ? "message" : eventName
                        let data = dataLines.joined(separator: "\n")
                        eventName = ""
                        dataLines = []
                        await handleSSEEvent(name: name, data: data)
                    } else if !line.hasPrefix(":") {
                        let (field, value) = Self.splitSSEField(line)
                        switch field {
                        case "event":
                            eventName = value
                        case "data":
                            dataLines.append(value)
                        default:
                            break  // id and retry are not needed
                        }
                    }
                }
                if let deadline, Date() >= deadline {
                    break
                }
            }
        } catch {
            // The stream ended (server closed it, the connection stopped,
            // or the read was cancelled).
        }

        // Requests still waiting on this stream will never get an answer.
        flushPending()
    }

    /// Handles one parsed SSE event. `endpoint` (legacy SSE) records the
    /// POST target; `message` carries a JSON-RPC message.
    private func handleSSEEvent(name: String, data: String) async {
        if name == "endpoint" {
            if let endpoint = URL(string: data, relativeTo: url) {
                sseEndpoint = endpoint
            }
            if let waiter = endpointWaiter {
                endpointWaiter = nil
                waiter.resume(returning: sseEndpoint)
            }
            return
        }
        if name == "message" {
            await dispatchInbound(data.data(using: .utf8) ?? Data())
        }
    }

    /// Splits one SSE line into its field and value (a single optional
    /// space after the colon is stripped, per the SSE spec).
    private static func splitSSEField(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = line[..<colon]
        var value = line[line.index(after: colon)...]
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return (String(field), String(value))
    }

    // MARK: - HTTP Plumbing

    /// A request to the server carrying the declared auth headers plus the
    /// negotiated Mcp-Session-Id (Streamable HTTP).
    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in descriptor.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let serverSessionID {
            request.setValue(serverSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        return request
    }

    // MARK: - Debug Log

    /// The debug mirror of every tools/call, appended next to the process
    /// as mcp_http.log.
    private static func appendDebugLog(server: String, name: String, argsJSON: String, result: String) {
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("mcp_http.log")
        guard let url else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry =
            "\n===== \(timestamp) — \(server)/\(name) =====\n" +
            "args: \(argsJSON)\n" +
            "result: \(result)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                var data = try Data(contentsOf: url)
                data.append(entry.data(using: .utf8) ?? Data())
                try data.write(to: url)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try entry.data(using: .utf8)?.write(to: url)
            }
        } catch {
            // Debug logging must never break the agent loop.
        }
    }

    /// Compact JSON for error echoes.
    private static func jsonString(_ object: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return json
    }
}
