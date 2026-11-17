//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// MCPStdioClientTests.swift
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

@Suite("MCP stdio client")
struct MCPStdioClientTests {
    // MARK: - Descriptor parsing

    @Test("parses stdio servers with the ACP env list form")
    func parsesStdioWithEnvList() {
        let params: [String: Any] = [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "ide-tools",
                    "command": "nc",
                    "args": ["127.0.0.1", "49548"],
                    "env": [
                        ["name": "MCP_AUTH_TOKEN", "value": "24a5fd0d-9fcc-4e0c-b281-0a6dcc5f8587"]
                    ],
                ]
            ]
        ]

        let descriptors = MCPServerDescriptor.parse(from: params, cwd: "/tmp/project")
        #expect(descriptors.count == 1)
        #expect(descriptors[0].name == "ide-tools")
        #expect(descriptors[0].command == "nc")
        #expect(descriptors[0].args == ["127.0.0.1", "49548"])
        #expect(descriptors[0].env["MCP_AUTH_TOKEN"] == "24a5fd0d-9fcc-4e0c-b281-0a6dcc5f8587")
        #expect(descriptors[0].cwd == "/tmp/project")
    }

    @Test("parses stdio servers with a plain env map")
    func parsesStdioWithEnvMap() {
        let params: [String: Any] = [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "tools",
                    "command": "my-mcp-server",
                    "env": ["KEY": "value"],
                ]
            ]
        ]

        let descriptors = MCPServerDescriptor.parse(from: params, cwd: nil)
        #expect(descriptors.count == 1)
        #expect(descriptors[0].env["KEY"] == "value")
        #expect(descriptors[0].cwd == nil)
    }

    @Test("skips unsupported and malformed entries")
    func skipsUnsupportedEntries() {
        let params: [String: Any] = [
            "mcpServers": [
                [
                    "type": "websocket",
                    "name": "remote",
                    "url": "ws://example.com/mcp",
                ],
                [
                    "type": "http",
                    "name": "no-url",
                ],
                [
                    "type": "stdio",
                    "name": "no-command",
                ],
                [
                    "type": "stdio",
                    "command": "no-name",
                ],
                [
                    "type": "stdio",
                    "name": "good",
                    "command": "echo",
                ],
            ]
        ]

        let descriptors = MCPServerDescriptor.parse(from: params, cwd: nil)
        #expect(descriptors.count == 1)
        #expect(descriptors[0].name == "good")
        #expect(descriptors[0].command == "echo")
    }

    @Test("missing mcpServers yields no descriptors")
    func missingServersYieldsNone() {
        #expect(MCPServerDescriptor.parse(from: nil, cwd: "/tmp").isEmpty)
        #expect(MCPServerDescriptor.parse(from: [:], cwd: "/tmp").isEmpty)
        #expect(MCPServerDescriptor.parse(from: ["mcpServers": []], cwd: "/tmp").isEmpty)
    }

    @Test("a server that never answers yields no tools instead of hanging")
    func silentServerYieldsNoTools() async throws {
        // `cat` just echoes every request line back; the client skips or
        // answers those echoes, so the deadline-bounded reads must give up
        // instead of blocking forever.
        let client = MCPStdioClient(
            descriptor: MCPServerDescriptor(name: "silent", command: "cat"),
            logger: NoOpLogger(),
            handshakeTimeout: 0.25
        )
        try await client.start()

        let start = Date()
        let tools = await client.fetchTools()
        #expect(tools.isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)

        await client.stop()
    }

    @Test("a server that answers late still completes the handshake")
    func lateAnswerCompletesHandshake() async throws {
        // The fake server sleeps before answering, so each response lands
        // while readLine is already blocked on its condition. With the old
        // queue.sync-based read, the DispatchSource handler was queued
        // behind the waiting block on the same serial queue, so no response
        // could ever be read and every handshake timed out.
        let script = """
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              sleep 0.5
              printf '%s\\n' '{"jsonrpc":"2.0","id":1001,"result":{"protocolVersion":"2025-03-26"}}'
              ;;
            *'"method":"tools/list"'*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":1002,"result":{"tools":[{"name":"late","description":"late tool","inputSchema":{"type":"object","properties":{}}}]}}'
              ;;
          esac
        done
        """
        let client = MCPStdioClient(
            descriptor: MCPServerDescriptor(
                name: "late",
                command: "/bin/sh",
                args: ["-c", script]
            ),
            logger: NoOpLogger(),
            handshakeTimeout: 2
        )

        let start = Date()
        try await client.start()
        // A late answer must be delivered, not waited out with the full
        // 2s handshake timeout.
        #expect(Date().timeIntervalSince(start) < 1.5)

        let tools = await client.fetchTools()
        #expect(tools.count == 1)
        #expect(tools.first?.function.name == "late")

        await client.stop()
    }

    @Test("a failed handshake makes fetchTools fail fast")
    func failedHandshakeMakesFetchToolsFailFast() async throws {
        // Swallows stdin and never writes, so the initialize handshake
        // times out. fetchTools must then return immediately instead of
        // waiting out the handshake timeout a second time for tools/list.
        let client = MCPStdioClient(
            descriptor: MCPServerDescriptor(
                name: "silent",
                command: "/bin/sh",
                args: ["-c", "cat > /dev/null"]
            ),
            logger: NoOpLogger(),
            handshakeTimeout: 0.5
        )
        try await client.start()

        let start = Date()
        let tools = await client.fetchTools()
        #expect(tools.isEmpty)
        #expect(Date().timeIntervalSince(start) < 0.3)

        await client.stop()
    }

    @Test("an unresolvable executable throws")
    func unresolvableExecutableThrows() async {
        let client = MCPStdioClient(
            descriptor: MCPServerDescriptor(
                name: "missing",
                command: "/nonexistent/definitely-not-a-tool"
            ),
            logger: NoOpLogger()
        )
        await #expect(throws: MCPStdioClientError.self) {
            try await client.start()
        }
    }
}
