//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ToolProvider.swift
//

import Foundation
import Stores

/// The outcome of a tool execution. Most tools produce text only; read_file
/// can additionally return an image attachment (when it reads an image
/// file), which the agent attaches to the tool-result message so a vision
/// model can see it.
public struct ToolResult: Sendable {
    public let text: String
    public let image: ImageAttachment?

    public init(text: String, image: ImageAttachment? = nil) {
        self.text = text
        self.image = image
    }

    /// Wraps a plain text result.
    public init(_ text: String) {
        self.init(text: text)
    }
}

/// A source of tools the agent can call (client-declared MCP servers, web
/// tools, ...).
public protocol ToolProvider: Sendable {
    func definitions() async -> [ToolDefinition]
    func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async -> ToolResult
}

/// Routes tool calls to the provider that owns the tool.
public struct ToolRegistry: Sendable {
    private let providers: [any ToolProvider]

    public init(_ providers: [any ToolProvider]) {
        self.providers = providers
    }

    /// A new registry that layers `additional` providers on top of this
    /// one's, for use by a single turn. Session-scoped MCP clients live
    /// here instead of in the shared registry so one session's IDE tools
    /// are never mixed into (and duplicated in) another session's.
    public func combined(with additional: [any ToolProvider]) -> ToolRegistry {
        ToolRegistry(providers + additional)
    }

    public func definitions() async -> [ToolDefinition] {
        var all: [ToolDefinition] = []
        // Tool names must be unique in the LLM request (servers such as
        // llama.cpp reject duplicates with a 400), so the first provider
        // to advertise a name wins — the same order execute() routes by.
        var seen = Set<String>()
        for provider in providers {
            for definition in await provider.definitions()
                where seen.insert(definition.function.name).inserted
            {
                all.append(definition)
            }
        }
        return all
    }

    public func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async -> ToolResult {
        for provider in providers {
            let providerTools = await provider.definitions()
            guard providerTools.contains(where: { $0.function.name == name }) else {
                continue
            }
            return await provider.execute(
                name: name,
                argsJSON: argsJSON,
                cwd: cwd,
                sessionId: sessionId,
                sendJSON: sendJSON
            )
        }
        return ToolResult("Error: Unknown tool '\(name)'")
    }
}
