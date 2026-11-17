//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// MCPStdioClient.swift
//

import Foundation
import Logger
import Stores

/// One entry of the ACP `mcpServers` parameter in a session/new or
/// session/load request (e.g. the "ide-tools" bridge Android Studio
/// declares per session).
public struct MCPServerDescriptor: Sendable {
    /// The transport a declared MCP server uses.
    public enum Transport: Sendable {
        /// Line-buffered JSON-RPC over a spawned process's stdio.
        case stdio(command: String, args: [String], env: [String: String])
        /// MCP Streamable HTTP (spec 2025-03-26): one POST per message,
        /// with an optional `Mcp-Session-Id` header.
        case http(url: String, headers: [String: String])
        /// Legacy MCP HTTP+SSE transport (spec 2024-11-05): a persistent
        /// event stream plus a POST endpoint.
        case sse(url: String, headers: [String: String])
    }

    public let name: String
    public let transport: Transport
    /// The session's working directory, used as the server process's cwd
    /// (stdio only).
    public let cwd: String?

    /// Convenience for the common case of a stdio server.
    public init(
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        cwd: String? = nil
    ) {
        self.name = name
        self.transport = .stdio(command: command, args: args, env: env)
        self.cwd = cwd
    }

    public init(name: String, transport: Transport, cwd: String? = nil) {
        self.name = name
        self.transport = transport
        self.cwd = cwd
    }

    // MARK: Convenience accessors

    /// The executable to spawn (stdio only).
    public var command: String? {
        if case .stdio(let command, _, _) = transport {
            return command
        }
        return nil
    }

    /// The process's arguments (stdio only).
    public var args: [String] {
        if case .stdio(_, let args, _) = transport {
            return args
        }
        return []
    }

    /// The process's extra environment variables (stdio only).
    public var env: [String: String] {
        if case .stdio(_, _, let env) = transport {
            return env
        }
        return [:]
    }

    /// The endpoint URL (http and sse only).
    public var url: String? {
        switch transport {
        case .http(let url, _):
            return url
        case .sse(let url, _):
            return url
        case .stdio:
            return nil
        }
    }

    /// The HTTP headers the client declares for the server (http and sse
    /// only), e.g. an Authorization bearer token.
    public var headers: [String: String] {
        switch transport {
        case .http(_, let headers):
            return headers
        case .sse(_, let headers):
            return headers
        case .stdio:
            return [:]
        }
    }

    /// Parses the `mcpServers` array out of ACP session params. Entries
    /// with a name and a usable command (stdio) or URL (http, sse) are
    /// kept; everything else (other flavors, malformed entries) is
    /// skipped. A missing type is treated as stdio when a command is
    /// present, so simpler clients still get their servers started. The ACP
    /// spec spells env and headers as lists of {name, value} objects; plain
    /// maps are accepted too for lenient clients.
    public static func parse(from params: [String: Any]?, cwd: String?) -> [MCPServerDescriptor] {
        guard let servers = params?["mcpServers"] as? [[String: Any]] else { return [] }
        var descriptors: [MCPServerDescriptor] = []
        for server in servers {
            let type = (server["type"] as? String)?.lowercased() ?? "stdio"

            switch type {
            case "stdio":
                guard
                    let name = server["name"] as? String,
                    let command = server["command"] as? String
                else { continue }

                descriptors.append(
                    MCPServerDescriptor(
                        name: name,
                        command: command,
                        args: (server["args"] as? [String]) ?? [],
                        env: Self.nameValuePairs(server["env"]),
                        cwd: cwd
                    )
                )

            case "http", "sse":
                guard
                    let name = server["name"] as? String,
                    let url = server["url"] as? String,
                    !url.isEmpty
                else { continue }

                let headers = Self.nameValuePairs(server["headers"])
                let transport: Transport =
                    type == "http"
                        ? .http(url: url, headers: headers)
                        : .sse(url: url, headers: headers)
                descriptors.append(
                    MCPServerDescriptor(name: name, transport: transport, cwd: cwd)
                )

            default:
                // Unknown flavor: skip.
                continue
            }
        }
        return descriptors
    }

    /// Reads an ACP name/value list (env, headers) as a map. The spec
    /// spells it as a list of {name, value} objects; a plain map is
    /// accepted too.
    private static func nameValuePairs(_ raw: Any?) -> [String: String] {
        if let entries = raw as? [[String: Any]] {
            var pairs: [String: String] = [:]
            for entry in entries {
                if let key = entry["name"] as? String,
                   let value = entry["value"] as? String
                {
                    pairs[key] = value
                }
            }
            return pairs
        }
        return (raw as? [String: String]) ?? [:]
    }
}

/// Failure to spawn a declared MCP server.
public enum MCPStdioClientError: Error, CustomStringConvertible {
    case executableNotFound(String)

    public var description: String {
        switch self {
        case .executableNotFound(let command):
            return "MCP executable not found: \(command)"
        }
    }
}

/// A client for one stdio MCP server declared by the ACP client. Unlike
/// XcodeMCPBridgeClient it carries no Xcode-specific retry logic and — for
/// now — no tool allowlist: every tool the server advertises is exposed to
/// the model.
///
/// The transport is line-buffered JSON-RPC over the process's stdio, per
/// the MCP stdio spec, and every read is deadline-bounded so a server that
/// never answers can never wedge the ACP stdin loop.
public actor MCPStdioClient: MCPClientHandle {
    /// Handshake reads (initialize, tools/list) give up after this long.
    private let handshakeTimeout: TimeInterval
    /// Tool calls may run long IDE operations (builds, tests).
    private let toolCallTimeout: TimeInterval

    private let descriptor: MCPServerDescriptor
    private let logger: Loggable
    private let debugLog: Bool

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var transport: LineTransport?
    private var tools: [ToolDefinition] = []
    private var nextRequestId = 1000
    private var started = false
    /// True once the server answered `initialize` with a result. Gates the
    /// `notifications/initialized` step and tools/list so a dead server is
    /// never waited out a second time.
    private var handshakeSucceeded = false

    public init(
        descriptor: MCPServerDescriptor,
        logger: Loggable,
        debugLog: Bool = false,
        handshakeTimeout: TimeInterval = 10,
        toolCallTimeout: TimeInterval = 600
    ) {
        self.descriptor = descriptor
        self.logger = logger
        self.debugLog = debugLog
        self.handshakeTimeout = handshakeTimeout
        self.toolCallTimeout = toolCallTimeout
    }

    /// True once `start()` has spawned the server process.
    public var isStarted: Bool { started }
    public var serverName: String { descriptor.name }

    public func definitions() async -> [ToolDefinition] { tools }

    /// Spawns the server process and runs the MCP handshake
    /// (initialize → notifications/initialized). A server that starts but
    /// never answers is kept running but yields no tools: the initialized
    /// notification is skipped and fetchTools() short-circuits instead of
    /// waiting out another full timeout. Only an unresolvable executable
    /// throws.
    public func start() throws {
        guard case .stdio(let command, let args, let env) = descriptor.transport else {
            preconditionFailure("MCPStdioClient requires a stdio transport")
        }
        guard let executable = Self.resolveExecutable(command) else {
            throw MCPStdioClientError.executableNotFound(command)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment
        if let cwd = descriptor.cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(filePath: cwd)
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe

        try process.run()

        self.process = process
        self.inputPipe = inPipe
        self.outputPipe = outPipe
        self.transport = LineTransport(
            fileDescriptor: outPipe.fileHandleForReading.fileDescriptor
        )
        started = true

        // Step 1 of the MCP handshake. The server's response carries the
        // negotiated protocol version; we do not act on it.
        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": nextID(),
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "Terrapin", "version": "1.0.0"],
            ],
        ]
        let initResponse = sendRPC(initRequest, timeout: handshakeTimeout)
        handshakeSucceeded = initResponse?["result"] != nil
        if !handshakeSucceeded {
            logger.debug("MCP server '\(descriptor.name)': no response to initialize")
        }

        // Step 2: the mandatory initialized notification. Only sent when the
        // server actually answered initialize; otherwise there is nothing
        // further to negotiate.
        if handshakeSucceeded {
            sendLine([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            ])
        }
    }

    /// Fetches every tool the server advertises (tools/list). First pass:
    /// no allowlist, unlike the Xcode bridge.
    @discardableResult
    public func fetchTools() async -> [ToolDefinition] {
        // The server never completed the handshake, so a tools/list request
        // would only wait out the full handshake timeout again. Fail fast
        // with no tools.
        guard handshakeSucceeded else { return [] }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": nextID(),
            "method": "tools/list",
        ]
        guard
            let response = sendRPC(request, timeout: handshakeTimeout),
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

    public func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: ([String: Any]) -> Void
    ) async -> ToolResult {
        let callId = "call_" + UUID().uuidString
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "name": name,
                    "title": name,
                    "kind": "execute",
                    "status": "in_progress"
                ]
            ]
        ])

        let (text, image, isFailure) = callTool(name: name, argsJSON: argsJSON)
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

    /// Terminates the server process and releases its pipes.
    public func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        transport?.cancel()
        process = nil
        inputPipe = nil
        outputPipe = nil
        transport = nil
        started = false
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Tool Calls

    private func callTool(name: String, argsJSON: String)
        -> (text: String, image: ImageAttachment?, isFailure: Bool)
    {
        let argsDict: [String: Any] =
            (try? JSONSerialization.jsonObject(
                with: argsJSON.data(using: .utf8) ?? Data()
            ) as? [String: Any]) ?? [:]

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": nextID(),
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": argsDict,
            ],
        ]

        guard let response = sendRPC(request, timeout: toolCallTimeout) else {
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

    // MARK: - Low-Level Line-Buffered JSON-RPC Transport

    private func nextID() -> Int {
        nextRequestId += 1
        return nextRequestId
    }

    private func sendLine(_ json: [String: Any]) {
        // Slashes stay unescaped so method names like tools/list appear
        // verbatim on the wire.
        guard
            let inputPipe,
            let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.withoutEscapingSlashes]
            )
        else { return }
        var line = data
        line.append(0x0A)
        inputPipe.fileHandleForWriting.write(line)
    }

    /// Sends a request and returns the response matching its id.
    /// Server-to-client requests (e.g. ping) are answered with an empty
    /// result so the server never blocks on us; notifications and non-JSON
    /// lines are skipped. Returns nil on timeout or EOF.
    private func sendRPC(_ request: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard let transport, let id = request["id"] as? Int else { return nil }
        sendLine(request)

        while let raw = transport.readLine(timeout: timeout) {
            guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
            else { continue }

            if let method = json["method"] as? String {
                if let responseId = json["id"] {
                    logger.debug(
                        "MCP '\(descriptor.name)': answering server request '\(method)' with an empty result"
                    )
                    sendLine([
                        "jsonrpc": "2.0",
                        "id": responseId,
                        "result": [:],
                    ])
                }
                // A server notification has nothing to do.
                continue
            }

            if let responseId = json["id"] as? Int {
                return responseId == id ? json : nil
            }
        }
        return nil
    }

    /// Resolves a command to an absolute executable URL. Commands containing
    /// a slash must point at an existing file; bare names are searched
    /// through $PATH the way a shell would (e.g. "nc" → /usr/bin/nc).
    static func resolveExecutable(_ command: String) -> URL? {
        if command.contains("/") {
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: command, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { return nil }
            return URL(filePath: command)
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = URL(filePath: String(directory)).appendingPathComponent(command)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                return candidate
            }
        }
        return nil
    }

    /// Appends a record for a server tool call to ~/.terrapin/logs/
    /// mcp_stdio.log so the raw MCP response for every tool operation can
    /// be inspected. Only called when debugLog is enabled.
    private static func appendDebugLog(
        server: String,
        name: String,
        argsJSON: String,
        result: String
    ) {
        let directory = TerrapinPaths.logsDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let logURL = directory.appendingPathComponent("mcp_stdio.log")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let flattenedArgs = argsJSON.replacingOccurrences(of: "\n", with: " ")
        let flattenedResult = result.replacingOccurrences(of: "\n", with: " \\n ")
        let record = """
        [\(timestamp)] \(server)/\(name)
          args: \(flattenedArgs)
          result: \(flattenedResult)

        """

        guard let data = record.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL)
        {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func jsonString(_ object: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return string
    }
}

// MARK: - Line Transport

/// Line-buffered reader for a pipe's file descriptor with deadline-bounded
/// reads. Data arrives on a dedicated serial dispatch queue via a
/// DispatchSource read event; waiters block on a condition variable until a
/// full line is buffered, EOF, or the deadline elapses.
private final class LineTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "terrapin.mcp-stdio")
    private let handle: FileHandle
    private let source: DispatchSourceRead
    private let condition = NSCondition()
    private var buffer = Data()
    private var isEOF = false

    init(fileDescriptor: Int32) {
        self.handle = FileHandle(fileDescriptor: fileDescriptor)
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        self.source = source
        // The handler captures self, so it can only be installed once every
        // stored property is initialized.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = read(self.handle.fileDescriptor, &bytes, bytes.count)
            self.condition.lock()
            defer { self.condition.unlock() }
            if count > 0 {
                self.buffer.append(bytes, count: count)
            } else if count == 0 {
                self.isEOF = true
            }
            // count < 0 (EAGAIN): spurious wakeup, nothing to do.
            self.condition.broadcast()
        }
        source.resume()
    }

    /// The next complete line (without its newline), or nil on EOF with an
    /// empty buffer or when the deadline elapses.
    ///
    /// The reader waits on `condition` directly, never inside `queue.sync`:
    /// the DispatchSource event handler is the only code that fills the
    /// buffer and broadcasts, and it runs on `queue`. A serial queue cannot
    /// run that handler while a `sync` block occupies the queue, so syncing
    /// here would deadlock every read until its deadline — or forever while
    /// the handler sits in a blocking read(), because the deadline is never
    /// even reached.
    func readLine(timeout: TimeInterval) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(..<buffer.index(after: newline))
                return Data(line)
            }
            if isEOF {
                let remainder = buffer
                buffer.removeAll()
                return remainder.isEmpty ? nil : remainder
            }
            if !condition.wait(until: deadline) {
                return nil
            }
        }
    }

    /// Wakes any waiting reader and tears the read source down.
    func cancel() {
        source.cancel()
        condition.lock()
        isEOF = true
        condition.broadcast()
        condition.unlock()
    }
}
