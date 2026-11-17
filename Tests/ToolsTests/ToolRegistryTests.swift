//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ToolRegistryTests.swift
//

import Foundation
import Stores
import Testing

@testable import Tools

/// A provider with a fixed tool list that echoes its own prefix in results,
/// so tests can tell which provider answered a call.
private struct StaticToolProvider: ToolProvider {
    let tools: [ToolDefinition]
    let prefix: String

    init(tools: [ToolDefinition], prefix: String) {
        self.tools = tools
        self.prefix = prefix
    }

    func definitions() async -> [ToolDefinition] { tools }

    func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: ([String: Any]) -> Void
    ) async -> ToolResult {
        ToolResult("\(prefix):\(name)")
    }
}

@Suite("Tool registry")
struct ToolRegistryTests {
    private func definition(_ name: String) -> ToolDefinition {
        ToolDefinition(
            function: FunctionDefinition(
                name: name,
                description: name,
                parameters: [:]
            )
        )
    }

    @Test("definitions dedupe repeated tool names, first provider wins")
    func dedupesDefinitions() async {
        let registry = ToolRegistry([
            StaticToolProvider(tools: [definition("a"), definition("b")], prefix: "p1"),
            StaticToolProvider(tools: [definition("b"), definition("c")], prefix: "p2"),
        ])

        let names = await registry.definitions().map { $0.function.name }
        #expect(names == ["a", "b", "c"])
    }

    @Test("combined layers session providers on top without mutating the base")
    func combinedLayersProviders() async {
        let base = ToolRegistry([StaticToolProvider(tools: [definition("base")], prefix: "base")])
        let turn = base.combined(with: [
            StaticToolProvider(tools: [definition("session")], prefix: "session"),
        ])

        let turnNames = await turn.definitions().map { $0.function.name }
        #expect(turnNames == ["base", "session"])

        let baseNames = await base.definitions().map { $0.function.name }
        #expect(baseNames == ["base"])
    }

    @Test("execute routes to the first provider that owns the tool")
    func executeRoutesByOwnership() async {
        let registry = ToolRegistry([
            StaticToolProvider(tools: [definition("dup")], prefix: "base"),
        ]).combined(with: [
            StaticToolProvider(tools: [definition("dup")], prefix: "session"),
        ])

        let result = await registry.execute(
            name: "dup",
            argsJSON: "{}",
            cwd: "/tmp",
            sessionId: "s",
            sendJSON: { _ in }
        )
        #expect(result.text == "base:dup")
    }
}
