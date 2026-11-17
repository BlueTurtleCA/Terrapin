//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// MCPHTTPClientTests.swift
//

import Foundation
import Logger
import Testing

@testable import Tools

private struct NoOpLogger: Loggable {
    func debug(_ message: String) {}
}

/// Records the `sessionUpdate`/`status` pairs arriving via sendJSON.
private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ json: [String: Any]) {
        let params = json["params"] as? [String: Any]
        let update = params?["update"] as? [String: Any]
        guard let sessionUpdate = update?["sessionUpdate"] as? String,
              let status = update?["status"] as? String
        else { return }
        lock.lock()
        defer { lock.unlock() }
        recorded.append("\(sessionUpdate):\(status)")
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

@Suite("MCP HTTP client")
struct MCPHTTPClientTests {
    // MARK: - Descriptor parsing

    @Test("parses http servers with a header list")
    func parsesHTTPServer() {
        let params: [String: Any] = [
            "mcpServers": [
                [
                    "type": "http",
                    "name": "ide-tools",
                    "url": "http://127.0.0.1:50117/mcp/conversations/abc",
                    "headers": [
                        ["name": "Authorization", "value": "Bearer fb0cad18"],
                    ],
                ]
            ]
        ]

        let descriptors = MCPServerDescriptor.parse(from: params, cwd: "/tmp/project")
        #expect(descriptors.count == 1)
        #expect(descriptors[0].name == "ide-tools")
        #expect(descriptors[0].url == "http://127.0.0.1:50117/mcp/conversations/abc")
        #expect(descriptors[0].headers["Authorization"] == "Bearer fb0cad18")
        #expect(descriptors[0].command == nil)
        #expect(descriptors[0].cwd == "/tmp/project")
    }

    @Test("parses sse servers and a plain header map")
    func parsesSSEServer() {
        let params: [String: Any] = [
            "mcpServers": [
                [
                    "type": "sse",
                    "name": "legacy",
                    "url": "https://example.com/sse",
                    "headers": ["Token": "abc"],
                ]
            ]
        ]

        let descriptors = MCPServerDescriptor.parse(from: params, cwd: nil)
        #expect(descriptors.count == 1)
        #expect(descriptors[0].name == "legacy")
        #expect(descriptors[0].url == "https://example.com/sse")
        #expect(descriptors[0].headers["Token"] == "abc")
    }

    // MARK: - Live round trips (require python3; skipped without it)

    @Test("streamable http handshake, tools/list and tools/call")
    func streamableRoundTrip() async throws {
        guard let (process, port) = Self.startFakeServer() else { return }
        defer { process.terminate() }

        let descriptor = MCPServerDescriptor(
            name: "fake",
            transport: .http(url: "http://127.0.0.1:\(port)/mcp", headers: [:])
        )
        let client = MCPHTTPClient(
            descriptor: descriptor,
            logger: NoOpLogger(),
            handshakeTimeout: 5
        )

        try await client.start()
        let tools = await client.fetchTools()
        #expect(tools.count == 1)
        #expect(tools.first?.function.name == "echo")

        let recorder = UpdateRecorder()
        let result = await client.execute(
            name: "echo",
            argsJSON: #"{"text":"hi"}"#,
            cwd: "/tmp",
            sessionId: "s1",
            sendJSON: recorder.record
        )
        #expect(result.text == "echo:hi")
        
        #expect(recorder.all == ["tool_call:in_progress", "tool_call_update:completed"])

        await client.stop()
    }

    @Test("legacy sse handshake and tool call")
    func sseRoundTrip() async throws {
        guard let (process, port) = Self.startFakeServer() else { return }
        defer { process.terminate() }

        let descriptor = MCPServerDescriptor(
            name: "fake",
            transport: .sse(url: "http://127.0.0.1:\(port)/sse", headers: [:])
        )
        let client = MCPHTTPClient(
            descriptor: descriptor,
            logger: NoOpLogger(),
            handshakeTimeout: 5
        )

        try await client.start()
        let tools = await client.fetchTools()
        #expect(tools.count == 1)
        #expect(tools.first?.function.name == "echo")

        let recorder = UpdateRecorder()
        let result = await client.execute(
            name: "echo",
            argsJSON: #"{"text":"there"}"#,
            cwd: "/tmp",
            sessionId: "s2",
            sendJSON: recorder.record
        )
        #expect(result.text == "echo:there")
        #expect(recorder.all == ["tool_call:in_progress", "tool_call_update:completed"])

        await client.stop()
    }

    @Test("an unreachable server yields no tools without hanging")
    func unreachableServerYieldsNoTools() async throws {
        // Port 1 refuses connections immediately; the handshake must give
        // up at its deadline and fetchTools must then fail fast.
        let descriptor = MCPServerDescriptor(
            name: "dead",
            transport: .http(url: "http://127.0.0.1:1/mcp", headers: [:])
        )
        let client = MCPHTTPClient(
            descriptor: descriptor,
            logger: NoOpLogger(),
            handshakeTimeout: 1
        )
        // A refused connection degrades to no tools; only an unusable URL
        // throws.
        try? await client.start()

        let start = Date()
        let tools = await client.fetchTools()
        #expect(tools.isEmpty)
        #expect(Date().timeIntervalSince(start) < 1)

        await client.stop()
    }

    // MARK: - Fake server

    /// Spawns the bundled fake MCP server (python3) and waits for it to
    /// print its bound port. Returns nil when python3 is missing or the
    /// server fails to start, in which case the live tests skip.
    private static func startFakeServer() -> (process: Process, port: Int)? {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", fakeServerScript]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        let handle = stdout.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while buffer.firstIndex(of: 0x0A) == nil, Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buffer.append(chunk)
        }
        guard
            let newline = buffer.firstIndex(of: 0x0A),
            let line = String(data: buffer[..<newline], encoding: .utf8),
            line.hasPrefix("LISTENING "),
            let port = Int(line.dropFirst("LISTENING ".count))
        else {
            process.terminate()
            return nil
        }
        return (process, port)
    }

    /// A minimal MCP server speaking both transports on one port:
    ///
    /// - `POST /mcp` — Streamable HTTP. Answers with JSON documents,
    ///   assigns a `Mcp-Session-Id` at initialization, and rejects every
    ///   later request that does not replay it (so the round trip proves
    ///   the client sends the header).
    /// - `GET /sse` + `POST /messages` — the legacy HTTP+SSE transport: the
    ///   stream's first `endpoint` event names the POST target, and every
    ///   response rides back on the stream.
    private static let fakeServerScript: String = #"""
import http.server
import json
import select
import threading

SESSION_ID = "fake-session-123"
STREAMS = []
WRITE_LOCK = threading.Lock()
TOOLS = {
    "tools": [
        {
            "name": "echo",
            "description": "Echoes its text argument",
            "inputSchema": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
            },
        }
    ]
}


def push(payload):
    data = "event: message\ndata: " + json.dumps(payload) + "\n\n"
    with WRITE_LOCK:
        for stream in list(STREAMS):
            try:
                stream.wfile.write(data.encode("utf-8"))
                stream.wfile.flush()
            except Exception:
                pass


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length)

    def json_reply(self, obj, status=200, session=False):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if session:
            self.send_header("Mcp-Session-Id", SESSION_ID)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def accepted(self):
        self.send_response(202)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def handle_rpc(self, msg, over_sse):
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            result = {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "serverInfo": {"name": "fake-mcp", "version": "0.1"},
            }
            reply = {"jsonrpc": "2.0", "id": mid, "result": result}
            if over_sse:
                push(reply)
                self.accepted()
            else:
                self.json_reply(reply, session=True)
        elif mid is None:
            self.accepted()
        else:
            if method == "tools/list":
                result = TOOLS
            elif method == "tools/call":
                args = msg.get("params", {}).get("arguments", {})
                result = {
                    "content": [
                        {"type": "text", "text": "echo:" + str(args.get("text", ""))}
                    ]
                }
            else:
                result = {}
            reply = {"jsonrpc": "2.0", "id": mid, "result": result}
            if over_sse:
                push(reply)
                self.accepted()
            else:
                self.json_reply(reply)

    def do_POST(self):
        try:
            msg = json.loads(self.read_body())
        except Exception:
            self.json_reply(
                {"jsonrpc": "2.0", "id": None,
                 "error": {"code": -32700, "message": "parse error"}},
                400,
            )
            return
        if self.path == "/messages":
            self.handle_rpc(msg, over_sse=True)
            return
        # /mcp (Streamable HTTP): everything except initialize must carry
        # the session id assigned at initialization.
        if (msg.get("method") != "initialize"
                and self.headers.get("Mcp-Session-Id") != SESSION_ID):
            self.json_reply(
                {"jsonrpc": "2.0", "id": msg.get("id"),
                 "error": {"code": -32000, "message": "missing session id"}},
                400,
            )
            return
        self.handle_rpc(msg, over_sse=False)

    def do_GET(self):
        if self.path != "/sse":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(b"event: endpoint\ndata: /messages\n\n")
        self.wfile.flush()
        STREAMS.append(self)
        try:
            while True:
                ready, _, _ = select.select([self.connection], [], [], 1.0)
                if ready and not self.connection.recv(1024):
                    break
        except Exception:
            pass
        try:
            STREAMS.remove(self)
        except ValueError:
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print("LISTENING " + str(server.server_address[1]), flush=True)
server.serve_forever()
"""#
}
