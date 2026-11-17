//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPToolCallUpdates.swift
//

import Foundation

/// Emitters for the ACP session/update tool-call notifications.
extension ACPClientTools {
    /// Emits a tool_call session/update. When terminalId is provided the
    /// terminal is embedded in the tool call so the client displays its
    /// live output (ACP spec: Terminals > Embedding in Tool Calls).
    static func sendToolCall(
        sessionId: String,
        callId: String,
        name: String,
        title: String,
        status: String,
        kind: String = "execute",
        locations: [[String: Any]]? = nil,
        content: [[String: Any]]? = nil,
        terminalId: String? = nil,
        sendJSON: ([String: Any]) -> Void
    ) {
        var update: [String: Any] = [
            "sessionUpdate": "tool_call",
            "toolCallId": callId,
            "name": name,
            "title": title,
            "kind": kind,
            "status": status,
        ]
        if let locations {
            update["locations"] = locations
        }
        if let content {
            update["content"] = content
        }
        if let terminalId {
            update["content"] = [
                ["type": "terminal", "terminalId": terminalId]
            ]
        }
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": update,
            ]
        ])
    }
    
    static func sendToolCallUpdate(
        sessionId: String,
        callId: String,
        status: String,
        title: String? = nil,
        locations: [[String: Any]]? = nil,
        content: [[String: Any]]? = nil,
        sendJSON: ([String: Any]) -> Void
    ) {
        var update: [String: Any] = [
            "sessionUpdate": "tool_call_update",
            "toolCallId": callId,
            "status": status,
        ]
        if let title {
            update["title"] = title
        }
        if let locations {
            update["locations"] = locations
        }
        if let content {
            update["content"] = content
        }
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": update,
            ]
        ])
    }
    
    /// The diff content block for a tool call/update: the client renders it
    /// as the before/after of the file change. A nil oldText (new file) is
    /// serialized as null, matching the ACP diff shape.
    static func diffContent(path: String, oldText: String?, newText: String) -> [[String: Any]] {
        [
            [
                "type": "diff",
                "path": path,
                "oldText": oldText ?? NSNull(),
                "newText": newText
            ]
        ]
    }
}
