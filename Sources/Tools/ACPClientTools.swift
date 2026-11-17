//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPClientTools.swift
//

import Foundation
import Stores

/// Native ACP client tools: the file and terminal tools the agent exposes
/// through the ACP client channel (with an Xcode MCP bridge fast path where
/// one is available).
///
/// The implementation is split by domain across several files so each tool's
/// behavior lives in one place; the model-facing schemas for all of them are
/// in ACP/ACPToolDefinitions.swift:
///
/// - ACP/ACPFileTools.swift — read_file, write_file, edit_file, move_file,
///   delete_file, list_directory (plus their local-disk fallbacks)
/// - ACP/ACPGrepTools.swift — grep_file (matching, file walking, glob support)
/// - ACP/ACPTerminalTools.swift — run_command, terminal_create,
///   terminal_output, terminal_wait_for_exit, terminal_kill, terminal_release
///   (plus the per-session terminal tracking)
/// - ACP/ACPWorkspacePaths.swift — argument parsing and workspace path
///   resolution shared by the tools
/// - ACP/ACPToolCallUpdates.swift — the session/update tool-call emitters
public final class ACPClientTools: ToolProvider, @unchecked Sendable {
    let clientChannel: ClientChannel
    let xcodeBridge: XcodeMCPBridgeClient?
    /// The server's explicit statement about the model's vision support
    /// (from /v1/models); nil when the server does not report it. When the
    /// server says no, image reads are refused and never advertised.
    let supportsVision: Bool?
    let lock = NSLock()
    private var capabilities = Capabilities()
    // Terminals still alive per session (created but not yet released), so
    // they can be released on session/cancel or session/delete. Each entry
    // remembers the tool call that embeds the terminal, so whoever releases
    // it last can close that call out.
    var activeTerminals: [String: [String: TrackedTerminal]] = [:]

    struct TrackedTerminal {
        let callId: String
    }
    
    public init(
        clientChannel: ClientChannel,
        xcodeBridge: XcodeMCPBridgeClient? = nil,
        supportsVision: Bool? = nil
    ) {
        self.clientChannel = clientChannel
        self.xcodeBridge = xcodeBridge
        self.supportsVision = supportsVision
    }
    
    private var currentCapabilities: Capabilities {
        lock.lock()
        defer { lock.unlock() }
        return capabilities
    }
    
    public func definitions() async -> [ToolDefinition] {
        var tools: [ToolDefinition] = []
        tools.append(readTextFileDefinition)
        tools.append(Self.writeTextFileDefinition)
        tools.append(Self.editTextFileDefinition)
        tools.append(Self.grepTextFileDefinition)
        tools.append(Self.moveFileDefinition)
        tools.append(Self.deleteFileDefinition)
        tools.append(Self.listDirectoryDefinition)
        if currentCapabilities.terminal {
            tools.append(contentsOf: Self.terminalDefinitions)
        }
        return tools
    }
    
    public func execute(name: String, argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> ToolResult {
        guard !sessionId.isEmpty else {
            return ToolResult("Error: No active ACP session")
        }

        switch name {
        case "read_file":
            // read_file can return an image attachment, not just text.
            return await readTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON)
        case "write_file":
            return ToolResult(await writeTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "edit_file":
            return ToolResult(await editTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "grep_file":
            return ToolResult(await grepTextFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "move_file":
            return ToolResult(await moveFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "delete_file":
            return ToolResult(await deleteFile(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "list_directory":
            return ToolResult(await listDirectory(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "run_command":
            return ToolResult(await runCommand(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "terminal_create":
            return ToolResult(await createTerminalTool(argsJSON: argsJSON, cwd: cwd, sessionId: sessionId, sendJSON: sendJSON))
        case "terminal_output":
            return ToolResult(await terminalOutput(argsJSON: argsJSON, sessionId: sessionId, sendJSON: sendJSON))
        case "terminal_wait_for_exit":
            return ToolResult(await terminalWaitForExit(argsJSON: argsJSON, sessionId: sessionId, sendJSON: sendJSON))
        case "terminal_kill":
            return ToolResult(await terminalKill(argsJSON: argsJSON, sessionId: sessionId, sendJSON: sendJSON))
        case "terminal_release":
            return ToolResult(await terminalRelease(argsJSON: argsJSON, sessionId: sessionId, sendJSON: sendJSON))
        default:
            return ToolResult("Error: Unknown tool '\(name)'")
        }
    }
    
    public func updateCapabilities(_ capabilities: Capabilities) {
        lock.lock()
        defer { lock.unlock() }
        self.capabilities = capabilities
    }
    
    /// Releases every terminal the session still holds and returns how many
    /// were released. Used on session/cancel and session/delete: a cancelled
    /// or deleted turn never gets to terminal_release its terminals itself,
    /// and the ACP spec makes the agent responsible for releasing terminals.
    /// The tool call that embeds each terminal (terminal_create) stays
    /// in_progress for the terminal's whole lifetime, so it is closed out
    /// here when the cleanup ends that lifetime. Per the spec,
    /// terminal/release kills the command if it is still running, so no
    /// separate kill is needed.
    public func releaseAllTerminals(for sessionId: String, sendJSON: @escaping @Sendable ([String: Any]) -> Void) async -> Int {
        let terminals = lock.withLock {
            let terminals = activeTerminals[sessionId] ?? [:]
            activeTerminals[sessionId] = nil
            return terminals
        }
        
        guard !terminals.isEmpty else { return 0 }
        
        // Released in parallel with a short deadline so an unresponsive
        // client cannot stall the cleanup.
        await withTaskGroup(of: Void.self) { group in
            for (terminalId, tracked) in terminals {
                group.addTask {
                    _ = await self.clientChannel.request(
                        method: "terminal/release",
                        params: ["sessionId": sessionId, "terminalId": terminalId],
                        timeout: 10
                    )
                    Self.sendToolCallUpdate(
                        sessionId: sessionId,
                        callId: tracked.callId,
                        status: "completed",
                        sendJSON: sendJSON
                    )
                }
            }
        }
        return terminals.count
    }
    
}
