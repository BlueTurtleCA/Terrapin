//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPWrapperTools.swift
//

import Foundation
import Stores

public final class ACPClientTools: ToolProvider, @unchecked Sendable {
    let clientChannel: ClientChannel
    let xcodeBridge: XcodeMCPBridgeClient?
    /// The server's explicit statement about the model's vision support
    /// (from /v1/models); nil when the server does not report it. When the
    /// server says no, image reads are refused and never advertised.
    let supportsVision: Bool?
    private let lock = NSLock()
    private var capabilities = Capabilities()
    // Terminals still alive per session (created but not yet released), so
    // they can be released on session/cancel or session/delete.
    private var activeTerminals: [String: Set<String>] = [:]
    
    enum ACPError: Error {
        case message(String)
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
    /// Per the spec, terminal/release kills the command if it is still
    /// running, so no separate kill is needed.
    public func releaseAllTerminals(for sessionId: String) async -> Int {
        let terminalIds = lock.withLock {
            let ids = Array(activeTerminals[sessionId] ?? [])
            activeTerminals[sessionId] = nil
            return ids
        }
        
        guard !terminalIds.isEmpty else { return 0 }
        
        // Released in parallel with a short deadline so an unresponsive
        // client cannot stall the cleanup.
        await withTaskGroup(of: Void.self) { group in
            for terminalId in terminalIds {
                group.addTask {
                    _ = await self.clientChannel.request(
                        method: "terminal/release",
                        params: ["sessionId": sessionId, "terminalId": terminalId],
                        timeout: 10
                    )
                }
            }
        }
        return terminalIds.count
    }
    
    // The description tracks the server's vision flag: when the server says
    // the model cannot see, the image claim is dropped so the model does not
    // attempt image reads it could never use.
    private var readTextFileDefinition: ToolDefinition {
        let description = supportsVision == false
            ? "Reads a file from the client's file system, including unsaved editor changes. Text files are returned as text; the current model cannot view image files. For any project files, you MUST use this call."
            : "Reads a file from the client's file system, including unsaved editor changes. Text files are returned as text; image files (PNG, JPEG, GIF, WebP, TIFF, BMP, HEIC) are returned as images you can see. For any project files, you MUST use this call."
        return ToolDefinition(
            function: FunctionDefinition(
                name: "read_file",
                description: description,
                parameters: Self.readTextFileParameters
            )
        )
    }
    
    private static let readTextFileParameters: [String: AnySendable] = [
        "type": AnySendable("object"),
        "properties": AnySendable([
            "path": AnySendable([
                "type": AnySendable("string"),
                "description": AnySendable("Path of the file to read. Relative paths are resolved against the working directory.")
            ]),
            "line": AnySendable([
                "type": AnySendable("integer"),
                "description": AnySendable("Optional 1-based line number to start reading from.")
            ]),
            "limit": AnySendable([
                "type": AnySendable("integer"),
                "description": AnySendable("Optional maximum number of lines to read.")
            ])
        ]),
        "required": AnySendable([AnySendable("path")])
    ]
    
    private static let writeTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "write_file",
            description: "Writes a complete file to the client's file system, creating any missing parent directories. For creating or overwriting any project files, you MUST use this call.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to write. Relative paths are resolved against the working directory.")
                    ]),
                    "content": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The full file content to write to the disk")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("content")])
            ]
        )
    )
    
    private static let editTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "edit_file",
            description: "Edits a file by replacing one text block for another. Edits MUST match the old text identically, including whitespace and newlines.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to read. Relative paths are resolved against the working directory.")
                    ]),
                    "existingText": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The existing text of the file to replace.")
                    ]),
                    "newText": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The text to overwrite the existingText with.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("existingText"), AnySendable("newText")])
            ]
        )
    )
    
    private static let grepTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "grep_file",
            description: "Searches workspace files for an extended regex pattern (e.g. 'foo|bar', 'func\\s+\\w+').",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The extended regex pattern to search for. Set isRegex to false to search for a literal string instead.")
                    ]),
                    "pathPattern": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional glob filter on file paths (e.g. '*.swift', 'Sources/*'). Patterns without '/' match the file name; patterns with '/' match the path relative to the workspace root. '*' does not cross directory boundaries; use '**' to match across directories.")
                    ]),
                    "caseSensitive": AnySendable([
                        "type": AnySendable("boolean"),
                        "description": AnySendable("Whether the search should be case sensitive. Defaults to false.")
                    ]),
                    "isRegex": AnySendable([
                        "type": AnySendable("boolean"),
                        "description": AnySendable("Whether to treat query as an extended regex pattern. Defaults to true. Set to false to search for a literal string.")
                    ])
                ]),
                "required": AnySendable([AnySendable("query")])
            ]
        )
    )
    
    private static let moveFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "move_file",
            description: "Moves or renames a file to a new path within the workspace, creating any missing parent directories at the destination. The destination must not already exist.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to move. Relative paths are resolved against the working directory.")
                    ]),
                    "newPath": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The new path for the file. Relative paths are resolved against the working directory.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("newPath")])
            ]
        )
    )
    
    private static let deleteFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "delete_file",
            description: "Deletes a file from the client's file system. Destructive and irreversible: only use when the user explicitly asked to delete the file.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to delete. Relative paths are resolved against the working directory.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path")])
            ]
        )
    )
    
    private static let listDirectoryDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "list_directory",
            description: "Lists the contents of a directory in the workspace, including file names and sizes.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Directory to list. Relative paths are resolved against the working directory. Defaults to the workspace root.")
                    ])
                ]),
                "required": AnySendable([AnySendable]())
            ]
        )
    )
    
    // The shell used to interpret full command lines (pipes, redirects,
    // multiple statements, ...) when the model puts them in `command`.
    #if os(Windows)
    private static let shellCommand = "powershell.exe"
    private static let shellArgs: [String] = ["-NoProfile", "-Command"]
    private static let shellInvocation = "powershell -Command"
    #else
    private static let shellCommand = "/bin/sh"
    private static let shellArgs: [String] = ["-c"]
    private static let shellInvocation = "/bin/sh -c"
    #endif

    private static let terminalDefinitions: [ToolDefinition] = [
        ToolDefinition(
            function: FunctionDefinition(
                name: "run_command",
                description: "Runs a shell command in a client terminal, waits for it to finish, and returns the exit status and output. Prefer this over Xcode MCP tools for shell commands (git, swift, xcodebuild, scripts, ...).",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "command": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The program to execute, e.g. 'git' — not a full command line; put arguments in `args`. For shell pipelines, redirects, command substitution, or multiple statements, put the entire line here (e.g. 'git status | grep modified') and leave `args` empty; it is then run via \(ACPClientTools.shellInvocation).")
                        ]),
                        "args": AnySendable([
                            "type": AnySendable("array"),
                            "items": AnySendable(["type": AnySendable("string")]),
                            "description": AnySendable("Command arguments as separate strings, e.g. [\"status\", \"-s\"]. No shell metacharacters — for those, use a full line in `command`.")
                        ]),
                        "cwd": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("Optional absolute working directory. Defaults to the session working directory.")
                        ]),
                        "env": AnySendable([
                            "type": AnySendable("object"),
                            "description": AnySendable("Optional environment variables as a key/value map.")
                        ]),
                        "timeoutSeconds": AnySendable([
                            "type": AnySendable("integer"),
                            "description": AnySendable("Optional maximum time to wait, in seconds (default 120, max 600). The command is killed when it elapses.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("command")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_create",
                description: "Starts a command in a new client terminal and returns its terminalId. Use the other terminal tools with that id to observe, wait for, kill, or release it. Prefer run_command for one-shot commands.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "command": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The command to execute, e.g. 'swift'.")
                        ]),
                        "args": AnySendable([
                            "type": AnySendable("array"),
                            "items": AnySendable(["type": AnySendable("string")]),
                            "description": AnySendable("Command arguments as separate strings.")
                        ]),
                        "cwd": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("Optional absolute working directory. Defaults to the session working directory.")
                        ]),
                        "env": AnySendable([
                            "type": AnySendable("object"),
                            "description": AnySendable("Optional environment variables as a key/value map.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("command")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_output",
                description: "Retrieves the current output of a terminal without waiting for the command to finish.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_wait_for_exit",
                description: "Waits until the command in a terminal finishes and returns its exit status.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_kill",
                description: "Kills the command running in a terminal without releasing it.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_release",
                description: "Releases a terminal that is no longer needed. Always release terminals you created.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        )
    ]
    
    // MARK: - Filesystem Tools

    private func readTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> ToolResult {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return ToolResult("Error: Invalid JSON parameters supplied to read_file")
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return ToolResult("Error: Missing 'path' parameter")
        }
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "read_file",
            title: "Reading \(fileName)",
            status: "in_progress",
            kind: "read",
            locations: [["path": path]],
            sendJSON: sendJSON
        )
        
        // Image files are read from the local disk (the ACP client and the
        // Xcode bridge only handle text) and returned as an attachment so a
        // vision model can see them. Other binaries are rejected up front
        // instead of producing garbled text.
        if let head = Self.peekHeadBytes(atPath: path), !head.isEmpty {
            if ImageSupport.mimeType(of: head) != nil {
                // The server said the model cannot see images: refuse up
                // front so the model does not burn turns on reads it could
                // never use.
                if supportsVision == false {
                    Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                    return ToolResult(
                        "Error: '\(path)' is an image file, but the current model does not support vision, so it cannot be viewed. Read text files instead."
                    )
                }
                switch ImageSupport.load(atPath: path) {
                case .loaded(let attachment, let width, let height):
                    let sizeKB = attachment.base64.count * 3 / 4 / 1024
                    let format = attachment.mimeType
                        .replacingOccurrences(of: "image/", with: "")
                        .uppercased()
                    Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                    return ToolResult(
                        text: "Image of '\(path)' (\(format), \(width)x\(height), \(sizeKB) KB). The image is attached to this result.",
                        image: attachment
                    )
                case .notAnImage:
                    break
                case .fileTooLarge(let bytes):
                    Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                    return ToolResult("Error: '\(path)' is too large to read as an image (\(bytes) bytes; the limit is \(ImageSupport.maxFileBytes)).")
                case .decodeFailed:
                    Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
                    return ToolResult("Error: '\(path)' looks like an image but could not be decoded.")
                }
            }
            if ImageSupport.looksBinary(head) {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                return ToolResult("Error: '\(path)' is a binary file, not text. read_file can read text files and image files (PNG, JPEG, GIF, WebP, TIFF, BMP, HEIC), but not other binary formats.")
            }
        }
        
        var params: [String: Any] = [
            "sessionId": sessionId,
            "path": path,
        ]
        if let line = args["line"] as? Int {
            params["line"] = line
        }
        if let limit = args["limit"] as? Int {
            params["limit"] = limit
        }
        
        // Prefer the Xcode bridge so reads see unsaved editor changes and
        // stay in sync with the IDE; fall back to the ACP client read when
        // the bridge is unavailable or the file is outside the project.
        if let bridge = xcodeBridge, await bridge.isStarted {
            var bridgeArgs: [String: Any] = [
                "filePath": Self.workspaceRelativePath(path, workspaceRoot: cwd)
            ]
            if let line = args["line"] as? Int {
                bridgeArgs["offset"] = line
            }
            if let limit = args["limit"] as? Int {
                bridgeArgs["limit"] = limit
            }
            let bridgeResult = await bridge.callTool(
                name: "XcodeRead",
                argsJSON: Self.makeArgsJSON(bridgeArgs),
                cwd: cwd
            )
            if let content = Self.parseXcodeReadContent(bridgeResult) {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                return ToolResult(content)
            }
        }
        
        do {
            switch await clientChannel.request(method: "fs/read_text_file", params: params) {
            case .result(let result):
                guard let response = result["content"] as? String else {
                    throw ACPError.message("Error reading text file: No content from \(path)")
                }
                
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                
                return ToolResult(response)
                
            case .error(let message):
                throw ACPError.message("Error reading text file \(path): message \(message)")
            }
        } catch {
            // The client could not answer (timeout, error, ...). The agent
            // runs on the same machine as the workspace, so fall back to
            // the local disk when the file exists there.
            if let local = Self.readLocalTextFile(path, line: args["line"] as? Int, limit: args["limit"] as? Int) {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                return ToolResult(local)
            }
            
            // Without a terminal update the client's tool-call spinner
            // would spin forever, so always close the call out.
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            
            if case ACPError.message(let reason) = error {
                return ToolResult(reason)
            }
            return ToolResult("Other error reading text file: \(error.localizedDescription)")
        }
    }
    
    private func writeTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to write_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty,
              let content = args["content"] as? String
                else {
            return "Error: Missing 'path' or 'content' parameter"
        }
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        let oldText = try? await internalReadTextFile(clientChannel: self.clientChannel, sessionId: sessionId, path: path)
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "write_file",
            title: "Writing \(fileName)",
            status: "in_progress",
            kind: "edit",
            locations: [["path": path]],
            content: oldText.map { Self.diffContent(path: path, oldText: $0, newText: content) },
            sendJSON: sendJSON
        )
        
        // Prefer the Xcode bridge so the IDE stays in sync (open editors,
        // project references for new files); fall back to the ACP client
        // write when it fails (e.g. the file is outside the project).
        if let bridge = xcodeBridge, await bridge.isStarted {
            let relPath = Self.workspaceRelativePath(path, workspaceRoot: cwd)
            let bridgeResult = await bridge.callTool(
                name: "XcodeWrite",
                argsJSON: Self.makeArgsJSON(["filePath": relPath, "content": content]),
                cwd: cwd
            )
            if !XcodeMCPBridgeClient.isBridgeError(bridgeResult) {
                Self.sendToolCallUpdate(
                    sessionId: sessionId,
                    callId: callId,
                    status: "completed",
                    locations: [["path": path]],
                    content: Self.diffContent(path: path, oldText: oldText, newText: content),
                    sendJSON: sendJSON
                )
                return "File written successfully: \(path)"
            }
        }
        
        // The ACP client creates the file itself but not its parent
        // directories (the spec only requires the file), and ACP has no
        // mkdir method. The agent runs on the same machine as the workspace,
        // so create any missing intermediate directories locally first.
        let parentDirectory = (path as NSString).deletingLastPathComponent
        if !parentDirectory.isEmpty, !FileManager.default.fileExists(atPath: parentDirectory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: parentDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
                return "Error creating parent directory for '\(path)': \(error.localizedDescription)"
            }
        }
        
        switch await clientChannel.request(
            method: "fs/write_text_file",
            params: ["sessionId": sessionId, "path": path, "content": content]
        ) {
        case .result:
            Self.sendToolCallUpdate(
                sessionId: sessionId,
                callId: callId,
                status: "completed",
                locations: [["path": path]],
                content: Self.diffContent(path: path, oldText: oldText, newText: content),
                sendJSON: sendJSON
            )
            
            return "File written successfully: \(path)"
        case .error(let message):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error writing '\(path)': \(message)"
        }
    }
    
    private func editTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to write_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty,
              let existingText = args["existingText"] as? String,
              let newText = args["newText"] as? String
                else {
            return "Error: Missing 'path' or 'existingText' or 'newText' parameter"
        }
        
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        guard let currentText = try? await internalReadTextFile(clientChannel: self.clientChannel, sessionId: sessionId, path: path) else {
            return "Error: Could not read text from \(path). Verify that this file exists before editing."
        }
        
        let occurrences = currentText.components(separatedBy: existingText).count - 1

        if occurrences == 0 {
            return "Error: Could not find 'old_string' in \(fileName). Verify exact indentation and line breaks."
        }

        if occurrences > 1 {
            return """
            Error: 'old_string' matched \(occurrences) locations in \(fileName). \
            Please include surrounding context lines (e.g., enclosing function name or adjacent variables) \
            so the target block is uniquely identifiable.
            """
        }

        let updatedText = currentText.replacingOccurrences(of: existingText, with: newText)
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "write_file",
            title: "Writing \(fileName)",
            status: "in_progress",
            kind: "edit",
            locations: [["path": path]],
            content: Self.diffContent(path: path, oldText: currentText, newText: updatedText),
            sendJSON: sendJSON
        )
        
        switch await clientChannel.request(
            method: "fs/write_text_file",
            params: ["sessionId": sessionId, "path": path, "content": updatedText]
        ) {
        case .result:
            Self.sendToolCallUpdate(
                sessionId: sessionId,
                callId: callId,
                status: "completed",
                locations: [["path": path]],
                content: Self.diffContent(path: path, oldText: currentText, newText: updatedText),
                sendJSON: sendJSON
            )
            
            return "File edited successfully: \(path)"
        case .error(let message):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error writing '\(path)': \(message)"
        }
    }
    
    private func grepTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to grep_file"
        }
        guard let query = args["query"] as? String, !query.isEmpty
                else {
            return "Error: Missing or empty 'query' parameter"
        }
        
        let pathPattern = args["pathPattern"] as? String
        let caseSensitive = args["caseSensitive"] as? Bool ?? false
        let isRegex = args["isRegex"] as? Bool ?? true
        
            
        let (matches, _, commandString) = await runStandardGrep(
            query: query,
            cwd: cwd,
            pathPattern: pathPattern,
            caseSensitive: caseSensitive,
            isRegex: isRegex
        )
        
        let resultText = matches.isEmpty ? "No matches found for '\(query)'." : matches.joined(separator: "\n")
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "grep_file",
            title: commandString,
            status: "in_progress",
            sendJSON: sendJSON
        )
        
        
        Self.sendToolCallUpdate(
            sessionId: sessionId,
            callId: callId,
            status: "completed",
            title: commandString,
            sendJSON: sendJSON
        )
            
        return resultText
    }
    
    private func moveFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to move_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty,
              let rawNewPath = args["newPath"] as? String, !rawNewPath.isEmpty
                else {
            return "Error: Missing 'path' or 'newPath' parameter"
        }
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let newPath = Self.resolveWorkspacePath(relativePath: rawNewPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let newFileName = URL(fileURLWithPath: newPath).lastPathComponent
        
        guard Self.isWithinWorkspace(path, workspaceRoot: cwd) else {
            return "Error: Refusing to move '\(path)': path is outside the workspace"
        }
        guard Self.isWithinWorkspace(newPath, workspaceRoot: cwd) else {
            return "Error: Refusing to move to '\(newPath)': path is outside the workspace"
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return "Error: Source file does not exist: \(path)"
        }
        guard !FileManager.default.fileExists(atPath: newPath) else {
            return "Error: Destination already exists: \(newPath)"
        }
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "move_file",
            title: "Moving \(fileName) to \(newFileName)",
            status: "in_progress",
            kind: "edit",
            locations: [
                ["path": path],
                ["path": newPath]
            ],
            sendJSON: sendJSON
        )
        
        // The destination's parent directory may not exist yet (a move into
        // a new subdirectory). Neither the Xcode bridge nor the ACP write
        // creates it, so create any missing intermediate directories locally.
        let destinationDirectory = (newPath as NSString).deletingLastPathComponent
        if !destinationDirectory.isEmpty, !FileManager.default.fileExists(atPath: destinationDirectory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: destinationDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
                return "Error creating parent directory for '\(newPath)': \(error.localizedDescription)"
            }
        }
        
        // Prefer the Xcode bridge so the IDE stays in sync (navigator, open
        // editors, project references); fall back to local operations.
        if let bridge = xcodeBridge, await bridge.isStarted {
            let from = Self.workspaceRelativePath(path, workspaceRoot: cwd)
            let to = Self.workspaceRelativePath(newPath, workspaceRoot: cwd)
            let bridgeResult = await bridge.callTool(
                name: "XcodeMV",
                argsJSON: Self.makeArgsJSON(["sourcePath": from, "destinationPath": to]),
                cwd: cwd
            )
            if !XcodeMCPBridgeClient.isBridgeError(bridgeResult) {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                return "File moved successfully: \(path) -> \(newPath)"
            }
        }
        
        // Compose the move from ACP primitives so the client tracks the new
        // file being written: read via the client, write via the client, then
        // remove the original locally (ACP has no delete method).
        do {
            let content = try await internalReadTextFile(clientChannel: self.clientChannel, sessionId: sessionId, path: path)
            try await internalWriteTextFile(clientChannel: self.clientChannel, sessionId: sessionId, path: newPath, content: content)
        } catch {
            // The file cannot round-trip as text (e.g. binary): move it directly.
            do {
                try FileManager.default.moveItem(atPath: path, toPath: newPath)
            } catch {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
                return "Error renaming '\(path)' to '\(newPath)': \(error.localizedDescription)"
            }
        }
        
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error: Created '\(newPath)' but failed to delete the original '\(path)': \(error.localizedDescription)"
        }
        
        Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
        
        return "File moved successfully: \(path) -> \(newPath)"
    }
    
    private func deleteFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to delete_file"
        }
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return "Error: Missing 'path' parameter"
        }
        let path = Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        guard Self.isWithinWorkspace(path, workspaceRoot: cwd) else {
            return "Error: Refusing to delete '\(path)': path is outside the workspace"
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return "Error: File does not exist: \(path)"
        }
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "delete_file",
            title: "Deleting \(fileName)",
            status: "in_progress",
            kind: "edit",
            locations: [["path": path]],
            sendJSON: sendJSON
        )
        
        // Prefer the Xcode bridge so the IDE stays in sync (navigator, open
        // editors, project references); fall back to local operations.
        if let bridge = xcodeBridge, await bridge.isStarted {
            let relPath = Self.workspaceRelativePath(path, workspaceRoot: cwd)
            let bridgeResult = await bridge.callTool(
                name: "XcodeRM",
                argsJSON: Self.makeArgsJSON(["path": relPath]),
                cwd: cwd
            )
            if !XcodeMCPBridgeClient.isBridgeError(bridgeResult) {
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
                return "File deleted successfully: \(path)"
            }
        }
        
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error deleting '\(path)': \(error.localizedDescription)"
        }
        
        Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
        
        return "File deleted successfully: \(path)"
    }
    
    private func listDirectory(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        let args = Self.parseArgs(argsJSON) ?? [:]
        let rawPath = (args["path"] as? String) ?? ""
        let path = rawPath.isEmpty ? cwd : Self.resolveWorkspacePath(relativePath: rawPath, workspaceRoot: cwd)
        let dirName = URL(fileURLWithPath: path).lastPathComponent
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "list_directory",
            title: "Listing \(dirName)",
            status: "in_progress",
            kind: "read",
            locations: [["path": path]],
            sendJSON: sendJSON
        )
        
        var result: String
        if let bridge = xcodeBridge, await bridge.isStarted {
            let relPath = Self.workspaceRelativePath(path, workspaceRoot: cwd)
            let bridgeResult = await bridge.callTool(
                name: "XcodeLS",
                argsJSON: Self.makeArgsJSON(["path": relPath]),
                cwd: cwd
            )
            result = XcodeMCPBridgeClient.isBridgeError(bridgeResult) ? runListDirectory(path) : bridgeResult
        } else {
            result = runListDirectory(path)
        }
        
        Self.sendToolCallUpdate(
            sessionId: sessionId,
            callId: callId,
            status: XcodeMCPBridgeClient.isBridgeError(result) ? "failed" : "completed",
            sendJSON: sendJSON
        )
        
        return result
    }
    
    // MARK: - Terminal Tools

    private enum CreatedTerminal {
        case id(String)
        case failure(String)
    }

    private func createTerminal(args: [String: Any], cwd: String, sessionId: String) async -> CreatedTerminal {
        guard let command = args["command"] as? String, !command.isEmpty else {
            return .failure("Error: Missing 'command' parameter")
        }
        let commandArgs = (args["args"] as? [String]) ?? []

        // A bare program name (the intended `command` value) has no spaces and
        // no shell metacharacters. If the agent instead put a full shell
        // command line in `command` (pipes, redirects, command substitution,
        // multiple statements, ...), re-express it as a shell invocation
        // (`/bin/sh -c "<line>"` on POSIX, `powershell -Command "<line>"` on
        // Windows) so the shell interprets it. Without this, the client tries
        // to exec the whole string as a single program name and fails.
        var finalCommand = command
        var finalArgs: [String] = commandArgs
        if Self.looksLikeShellCommandLine(command) {
            var line = command
            if !commandArgs.isEmpty {
                line += " " + commandArgs.joined(separator: " ")
            }
            finalCommand = Self.shellCommand
            finalArgs = Self.shellArgs + [line]
        }

        var params: [String: Any] = [
            "sessionId": sessionId,
            "command": finalCommand,
            "outputByteLimit": 1_048_576,
            "args": finalArgs,
            "env": [[String: String]]()
        ]
        if !cwd.isEmpty {
            params["cwd"] = cwd
        }
        if let rawCwd = args["cwd"] as? String, !rawCwd.isEmpty {
            params["cwd"] = Self.resolveWorkspacePath(relativePath: rawCwd, workspaceRoot: cwd)
        }
        if let env = args["env"] as? [String: Any], !env.isEmpty {
            params["env"] = env.map { key, value in
                ["name": key, "value": String(describing: value)]
            }
        }

        switch await clientChannel.request(method: "terminal/create", params: params) {
        case .result(let result):
            guard let terminalId = result["terminalId"] as? String else {
                return .failure("Error: Client did not return a terminalId")
            }
            trackTerminal(terminalId, in: sessionId)
            return .id(terminalId)
        case .error(let message):
            return .failure("Error creating terminal: \(message)")
        }
    }

    private func runCommand(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to run_command"
        }

        let callId = "call_" + UUID().uuidString
        let title = Self.commandTitle(args)

        let created = await createTerminal(args: args, cwd: cwd, sessionId: sessionId)
        guard case .id(let terminalId) = created else {
            if case .failure(let message) = created {
                Self.sendToolCall(sessionId: sessionId, callId: callId, name: "run_command", title: title, status: "in_progress", sendJSON: sendJSON)
                Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
                return message
            }
            return "Error: Failed to create terminal"
        }

        // Embed the terminal in the tool call so the client displays live
        // output as it is generated (ACP spec: Terminals > Embedding in
        // Tool Calls).
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "run_command",
            title: title,
            status: "in_progress",
            terminalId: terminalId,
            sendJSON: sendJSON
        )

        let timeout = min(max((args["timeoutSeconds"] as? Int) ?? 120, 1), 600)

        // ACP's terminal/wait_for_exit has no timeout of its own, so race it
        // against a local deadline: a hung command must not hang the agent.
        // The channel request gets a longer deadline than the race so the
        // race (not the channel) decides when the command has timed out.
        let exitResponse: ClientChannel.ClientResponse? = await withTaskGroup(
            of: ClientChannel.ClientResponse?.self
        ) { group in
            group.addTask {
                await self.clientChannel.request(
                    method: "terminal/wait_for_exit",
                    params: ["sessionId": sessionId, "terminalId": terminalId],
                    timeout: Double(timeout) + 30
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        var statusLine: String
        var finalStatus: String
        switch exitResponse {
        case nil:
            _ = await clientChannel.request(
                method: "terminal/kill",
                params: ["sessionId": sessionId, "terminalId": terminalId]
            )
            statusLine = "Command timed out after \(timeout)s and was killed."
            finalStatus = "failed"
        case .some(.result(let result)):
            // Per the ACP spec, terminal/wait_for_exit responds with a flat
            // {exitCode, signal} object; the nested exitStatus shape belongs
            // to terminal/output.
            statusLine = Self.describeExitStatus(result)
            // Exit code 0 (or no status at all) counts as completed; a
            // non-zero code or a terminating signal counts as failed.
            if let exitCode = result["exitCode"] as? Int {
                finalStatus = exitCode == 0 ? "completed" : "failed"
            } else {
                finalStatus = (result["signal"] as? String) == nil ? "completed" : "failed"
            }
        case .some(.error(let message)):
            statusLine = "Error waiting for the command to exit: \(message)"
            finalStatus = "failed"
        }

        var output = ""
        switch await clientChannel.request(
            method: "terminal/output",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result(let result):
            output = (result["output"] as? String) ?? ""
            if (result["truncated"] as? Bool) == true {
                output = "[output truncated]\n" + output
            }
        case .error(let message):
            output = "[failed to read terminal output: \(message)]"
        }

        _ = await clientChannel.request(
            method: "terminal/release",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        )
        untrackTerminal(terminalId, in: sessionId)

        Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: finalStatus, sendJSON: sendJSON)

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? statusLine : statusLine + "\n" + trimmed
    }

    private func createTerminalTool(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to terminal_create"
        }

        let callId = "call_" + UUID().uuidString
        let title = Self.commandTitle(args)

        switch await createTerminal(args: args, cwd: cwd, sessionId: sessionId) {
        case .id(let terminalId):
            // Embed the terminal in the tool call so the client displays
            // live output for the lifetime of the terminal.
            Self.sendToolCall(
                sessionId: sessionId,
                callId: callId,
                name: "terminal_create",
                title: title,
                status: "in_progress",
                terminalId: terminalId,
                sendJSON: sendJSON
            )
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
            return "Terminal created: \(terminalId)"
        case .failure(let message):
            Self.sendToolCall(sessionId: sessionId, callId: callId, name: "terminal_create", title: title, status: "in_progress", sendJSON: sendJSON)
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return message
        }
    }

    private func terminalOutput(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }

        let callId = "call_" + UUID().uuidString
        Self.sendToolCall(sessionId: sessionId, callId: callId, name: "terminal_output", title: "Reading output of \(terminalId)", status: "in_progress", sendJSON: sendJSON)

        switch await clientChannel.request(
            method: "terminal/output",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result(let result):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
            var text = (result["output"] as? String) ?? ""
            if (result["truncated"] as? Bool) == true {
                text = "[output truncated]\n" + text
            }
            if let status = result["exitStatus"] as? [String: Any] {
                text += "\n" + Self.describeExitStatus(status)
            }
            return text.isEmpty ? "(no output yet)" : text
        case .error(let message):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error reading terminal output: \(message)"
        }
    }

    private func terminalWaitForExit(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }

        let callId = "call_" + UUID().uuidString
        Self.sendToolCall(sessionId: sessionId, callId: callId, name: "terminal_wait_for_exit", title: "Waiting for \(terminalId) to exit", status: "in_progress", sendJSON: sendJSON)

        // Long-running commands (builds, test suites) can take far longer
        // than the channel's default 120 s deadline.
        switch await clientChannel.request(
            method: "terminal/wait_for_exit",
            params: ["sessionId": sessionId, "terminalId": terminalId],
            timeout: 3600
        ) {
        case .result(let result):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
            return Self.describeExitStatus(result)
        case .error(let message):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error waiting for terminal exit: \(message)"
        }
    }

    private func terminalKill(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }

        let callId = "call_" + UUID().uuidString
        Self.sendToolCall(sessionId: sessionId, callId: callId, name: "terminal_kill", title: "Killing \(terminalId)", status: "in_progress", sendJSON: sendJSON)

        switch await clientChannel.request(
            method: "terminal/kill",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result:
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
            return "Terminal \(terminalId) killed."
        case .error(let message):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error killing terminal: \(message)"
        }
    }

    private func terminalRelease(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let terminalId = Self.terminalId(from: argsJSON) else {
            return "Error: Missing 'terminalId' parameter"
        }

        let callId = "call_" + UUID().uuidString
        Self.sendToolCall(sessionId: sessionId, callId: callId, name: "terminal_release", title: "Releasing \(terminalId)", status: "in_progress", sendJSON: sendJSON)

        switch await clientChannel.request(
            method: "terminal/release",
            params: ["sessionId": sessionId, "terminalId": terminalId]
        ) {
        case .result:
            untrackTerminal(terminalId, in: sessionId)
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
            return "Terminal \(terminalId) released."
        case .error(let message):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error releasing terminal: \(message)"
        }
    }
    
    private func trackTerminal(_ terminalId: String, in sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        activeTerminals[sessionId, default: []].insert(terminalId)
    }
    
    private func untrackTerminal(_ terminalId: String, in sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        activeTerminals[sessionId]?.remove(terminalId)
        if activeTerminals[sessionId]?.isEmpty == true {
            activeTerminals[sessionId] = nil
        }
    }
    
    /// Reads the first `count` bytes of a file (for magic-byte sniffing)
    /// without loading the whole file. Returns nil when the file cannot be
    /// opened.
    private static func peekHeadBytes(atPath path: String, count: Int = 16 * 1024) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: count)
    }

    /// Reads a file directly from the local disk, applying the same 1-based
    /// `line` / `limit` window the ACP client read would apply. Returns nil
    /// when the file does not exist or is not valid UTF-8. Used as a
    /// fallback when the client cannot answer (timeout, error, ...), since
    /// the agent runs on the same machine as the workspace.
    private static func readLocalTextFile(_ path: String, line: Int?, limit: Int?) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        
        // Normalize CRLF line endings so lines don't carry a trailing \r.
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let start = max((line ?? 1) - 1, 0)
        guard start < lines.count else { return "" }
        let end = limit.map { min(start + max($0, 0), lines.count) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }
    
    private func internalReadTextFile(clientChannel: ClientChannel, sessionId: String, path: String) async throws -> String {
        do {            
            do {
                switch await clientChannel.request(method: "fs/read_text_file", params: [
                    "sessionId": sessionId,
                    "path": path,
                ]) {
                case .result(let result):
                    guard let response = result["content"] as? String else {
                        throw ACPError.message("Error reading text file: No content from \(path)")
                    }
                    return response
                    
                case .error(let message):
                    throw ACPError.message("Error reading text file \(path): message \(message)")
                }
            } catch {
                throw error
            }
        } catch {
            if let local = Self.readLocalTextFile(path, line: nil, limit: nil) {
                return local
            }
            throw error
        }
    }
    
    private func internalWriteTextFile(clientChannel: ClientChannel, sessionId: String, path: String, content: String) async throws {
        do {
            switch await clientChannel.request(
                method: "fs/write_text_file",
                params: ["sessionId": sessionId, "path": path, "content": content]
            ) {
            case .result:
                return
            case .error(let message):
                throw ACPError.message("Error writing text file \(path): message \(message)")
            }
        } catch {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    
    private static func parseArgs(_ argsJSON: String) -> [String: Any]? {
        guard let data = argsJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Replaces backslash separators with forward slashes. On Windows both
    /// characters are path separators (and "\" is never a file-name
    /// character), so the rewrite is always safe; on POSIX "\" is a legal
    /// file-name character and is left alone.
    private static func normalizedSeparators(_ path: String) -> String {
        #if os(Windows)
        return path.replacingOccurrences(of: "\\", with: "/")
        #else
        return path
        #endif
    }
    
    /// True when the path is absolute on the current platform: POSIX paths
    /// start with "/", Windows paths with a drive letter ("C:\", "C:/") or
    /// a UNC prefix ("\\server\share").
    private static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        #if os(Windows)
        let characters = Array(path)
        if characters.count >= 3,
           characters[0].isLetter,
           characters[1] == ":",
           characters[2] == "/" || characters[2] == "\\" {
            return true
        }
        if path.hasPrefix("\\\\") { return true }
        #endif
        return false
    }
    
    private static func resolveWorkspacePath(relativePath: String, workspaceRoot: String) -> String {
        let expandedRaw = (relativePath as NSString).expandingTildeInPath
        let expandedRoot = (workspaceRoot as NSString).expandingTildeInPath
        
        let rootURL = URL(fileURLWithPath: expandedRoot).standardizedFileURL
            
        // 1. Absolute paths (POSIX "/..." or Windows "C:\..." / UNC)
        if Self.isAbsolutePath(expandedRaw) {
            return URL(fileURLWithPath: expandedRaw).standardizedFileURL.path
        }
            
        // Normalize separators so the prefix check below works on every
        // platform (the model may write Windows paths with backslashes).
        let normalized = Self.normalizedSeparators(expandedRaw)
            
        // 2. Strip redundant workspace name prefix EVEN IF the file doesn't exist yet
        let rootName = rootURL.lastPathComponent // "Terrapin"
        var cleanRelative = normalized
        if normalized.hasPrefix("\(rootName)/") {
            cleanRelative = String(normalized.dropFirst(rootName.count + 1)) // "SUMMARY.md"
        }
            
        // 3. Resolve clean path against workspace root
        let resolvedURL = rootURL.appendingPathComponent(cleanRelative).standardizedFileURL
        return resolvedURL.path
    }
    
    private static func isWithinWorkspace(_ path: String, workspaceRoot: String) -> Bool {
        let root = Self.normalizedSeparators(
            URL(fileURLWithPath: (workspaceRoot as NSString).expandingTildeInPath).standardizedFileURL.path
        )
        let standardized = Self.normalizedSeparators(URL(fileURLWithPath: path).standardizedFileURL.path)
        return standardized == root || standardized.hasPrefix(root + "/")
    }
    
    /// The inverse of resolveWorkspacePath: a workspace-relative path in the
    /// form the Xcode MCP bridge expects (e.g. "Terrapin/Sources/Foo.swift").
    private static func workspaceRelativePath(_ absolutePath: String, workspaceRoot: String) -> String {
        let root = URL(fileURLWithPath: (workspaceRoot as NSString).expandingTildeInPath).standardizedFileURL
        let abs = URL(fileURLWithPath: absolutePath).standardizedFileURL
        let rootPath = Self.normalizedSeparators(root.path)
        let absPath = Self.normalizedSeparators(abs.path)
        guard absPath.hasPrefix(rootPath + "/") else {
            return absolutePath
        }
        let relative = String(absPath.dropFirst(rootPath.count + 1))
        return root.lastPathComponent + "/" + relative
    }
    
    private static func makeArgsJSON(_ args: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    
    /// XcodeRead answers with a JSON object whose `content` field holds the
    /// file in cat -n format (right-aligned line number, tab, text). Extracts
    /// that field and strips the line-number prefixes so the result matches
    /// the plain content the ACP read returns. Returns nil when the bridge
    /// result is not a successful XcodeRead response (error text, prose, ...),
    /// in which case the caller falls back to the ACP client read.
    private static func parseXcodeReadContent(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catN = json["content"] as? String
        else { return nil }
        return catN.replacingOccurrences(
            of: "^[ \\t]*\\d+\\t",
            with: "",
            options: .regularExpression
        )
    }
    
    private static func terminalId(from argsJSON: String) -> String? {
        parseArgs(argsJSON)?["terminalId"] as? String
    }
    
    private static func describeExitStatus(_ status: [String: Any]?) -> String {
        guard let status else { return "Command finished." }
        if let code = status["exitCode"] as? Int {
            return code == 0
                ? "Command finished with exit code 0."
                : "Command failed with exit code \(code)."
        }
        if let signal = status["signal"] as? String {
            return "Command terminated by signal \(signal)."
        }
        return "Command finished."
    }
    
    /// Builds a human-readable command line (e.g. "git status -s") for use
    /// as a tool call title.
    private static func commandTitle(_ args: [String: Any]) -> String {
        let command = args["command"] as? String ?? "command"
        if let commandArgs = args["args"] as? [String], !commandArgs.isEmpty {
            return command + " " + commandArgs.joined(separator: " ")
        }
        return command
    }
    
    /// True when a `command` value is a full shell command line rather than a
    /// bare program name. A program name has no spaces and no shell
    /// metacharacters; the presence of either means the value needs a shell to
    /// interpret it (pipes, redirects, command substitution, globs, multiple
    /// statements, ...). Used to transparently re-express such values as a
    /// shell invocation (`/bin/sh -c "<line>"` on POSIX,
    /// `powershell -Command "<line>"` on Windows) so the client's direct exec
    /// doesn't fail.
    private static func looksLikeShellCommandLine(_ command: String) -> Bool {
        let shellChars: Set<Character> = [
            " ", "\t", "\n", "|", ";", "&", ">", "<", "$", "`",
            "*", "?", "(", ")", "{", "}", "[", "]", "~", "!", "#"
        ]
        return command.contains(where: { shellChars.contains($0) })
    }
    
    /// Emits a tool_call session/update. When terminalId is provided the
    /// terminal is embedded in the tool call so the client displays its
    /// live output (ACP spec: Terminals > Embedding in Tool Calls).
    private static func sendToolCall(
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
    
    private static func sendToolCallUpdate(
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
    private static func diffContent(path: String, oldText: String?, newText: String) -> [[String: Any]] {
        [
            [
                "type": "diff",
                "path": path,
                "oldText": oldText ?? NSNull(),
                "newText": newText
            ]
        ]
    }
    
    private func runStandardGrep(
        query: String,
        cwd: String,
        pathPattern: String?,
        caseSensitive: Bool,
        isRegex: Bool
    ) async -> (matches: [String], locations: [[String: Any]], cmd: String) {
        // grep --include only matches file basenames, so a pattern with a
        // directory component (e.g. "Sources/*") can never match. Enumerate
        // the workspace instead and search the files whose relative path
        // matches the glob. Both separator styles count as directory
        // components ("Sources\*" on Windows).
        let searchTargets: [String]
        if let pattern = pathPattern, !pattern.isEmpty,
           pattern.contains("/") || pattern.contains("\\") {
            searchTargets = Self.filesMatchingGlob(pattern, under: cwd)
            if searchTargets.isEmpty {
                return (
                    ["No files match path pattern '\(pattern)'."],
                    [],
                    "grep (no files match '\(pattern)')"
                )
            }
        } else if let pattern = pathPattern, !pattern.isEmpty {
            // A basename-only pattern filters by file name (grep --include).
            searchTargets = Self.walkFiles(under: cwd)
                .filter { Self.globMatches(pattern, path: ($0.absolute as NSString).lastPathComponent) }
                .map(\.absolute)
        } else {
            searchTargets = Self.walkFiles(under: cwd).map(\.absolute)
        }
        
        // Extended regex by default so `|`, `+`, `?`, ... behave as most
        // models expect; literal matching otherwise (grep -F).
        let regex: NSRegularExpression?
        if isRegex {
            guard let compiled = try? NSRegularExpression(
                pattern: query,
                options: caseSensitive ? [] : [.caseInsensitive]
            ) else {
                return (
                    ["Grep execution failed: invalid regex '\(query)'."],
                    [],
                    "grep -E -e \(query)"
                )
            }
            regex = compiled
        } else {
            regex = nil
        }
        
        // A long explicit file list makes for an unreadable title, so show
        // the glob instead when the search was narrowed to matched files.
        let flags = "\(isRegex ? "-E" : "-F")\(caseSensitive ? "" : " -i")"
        let commandString: String
        if searchTargets.count > 1, let pattern = pathPattern {
            commandString = "grep \(flags) -e \(query) [\(searchTargets.count) files matching '\(pattern)']"
        } else {
            commandString = "grep \(flags) -e \(query) \(cwd)"
        }
        
        var matches: [String] = []
        var locations: [[String: Any]] = []
        
        searchTargetsLoop: for file in searchTargets {
            // Skip files that are not valid UTF-8 or contain NUL bytes
            // (grep -I).
            guard let content = try? String(contentsOfFile: file, encoding: .utf8),
                  !content.contains("\0")
            else { continue }
            
            for (index, line) in content.components(separatedBy: .newlines).enumerated() {
                let matched: Bool
                if let regex {
                    matched = regex.firstMatch(
                        in: line,
                        range: NSRange(line.startIndex..., in: line)
                    ) != nil
                } else {
                    matched = caseSensitive
                        ? line.contains(query)
                        : line.lowercased().contains(query.lowercased())
                }
                guard matched else { continue }
                
                let lineNumber = index + 1
                matches.append("\(file):\(lineNumber):\(line)")
                locations.append([
                    "path": file,
                    "line": lineNumber,
                    "column": 1
                ])
                
                // Report at most 100 matches, like the grep -r output cap.
                if matches.count >= 100 { break searchTargetsLoop }
            }
        }
        
        return (matches, locations, commandString)
    }
    
    /// Enumerates the regular files under `directory` (skipping .git, .build
    /// and DerivedData). Returns each file's absolute path plus its path
    /// relative to `directory` with forward slashes, so glob matching works
    /// the same on every platform.
    private static func walkFiles(under directory: String) -> [(absolute: String, relative: String)] {
        let fileManager = FileManager.default
        // Resolve symlinks (e.g. /var -> /private/var on macOS) so the
        // enumerated paths share the root's prefix.
        let rootURL = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        let excludedDirectories: Set<String> = [".git", ".build", "DerivedData"]
        
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            return []
        }
        
        let rootPath = rootURL.path.replacingOccurrences(of: "\\", with: "/")
        var files: [(absolute: String, relative: String)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true {
                let fileURL = url.standardizedFileURL
                let normalizedPath = fileURL.path.replacingOccurrences(of: "\\", with: "/")
                guard normalizedPath.hasPrefix(rootPath + "/") else { continue }
                files.append((fileURL.path, String(normalizedPath.dropFirst(rootPath.count + 1))))
            } else if values?.isDirectory == true, excludedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
            }
        }
        return files
    }
    
    /// Enumerates the regular files under `directory` (skipping .git, .build
    /// and DerivedData) whose path relative to `directory` matches the glob
    /// `pattern`.
    private static func filesMatchingGlob(_ pattern: String, under directory: String) -> [String] {
        walkFiles(under: directory).compactMap { file in
            globMatches(pattern, path: file.relative) ? file.absolute : nil
        }
    }
    
    /// Matches `path` against a shell-style glob: `*` matches any run of
    /// characters except a path separator, `**` matches anything including
    /// separators, `?` matches a single character except a separator, and
    /// every other character is literal.
    private static func globMatches(_ pattern: String, path: String) -> Bool {
        guard let regex = globRegex(for: pattern) else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
    
    /// Regex classes for `*` (any run) and `?` (single character): anything
    /// except a path separator. Windows treats both "/" and "\" as
    /// separators; POSIX only "/".
    #if os(Windows)
    private static let globSingleSegment = "[^/\\\\]*"
    private static let globSingleChar = "[^/\\\\]"
    #else
    private static let globSingleSegment = "[^/]*"
    private static let globSingleChar = "[^/]"
    #endif
    
    private static func globRegex(for pattern: String) -> NSRegularExpression? {
        // The paths being matched are slash-normalized, so backslash
        // separators in the pattern mean the same as forward slashes.
        let normalizedPattern = Self.normalizedSeparators(pattern)
        var source = "^"
        var index = normalizedPattern.startIndex
        while index < normalizedPattern.endIndex {
            let character = normalizedPattern[index]
            switch character {
            case "*":
                let next = normalizedPattern.index(after: index)
                if next < normalizedPattern.endIndex, normalizedPattern[next] == "*" {
                    source += ".*"
                    index = normalizedPattern.index(after: next)
                } else {
                    source += Self.globSingleSegment
                    index = next
                }
            case "?":
                source += Self.globSingleChar
                index = normalizedPattern.index(after: index)
            default:
                source += NSRegularExpression.escapedPattern(for: String(character))
                index = normalizedPattern.index(after: index)
            }
        }
        source += "$"
        return try? NSRegularExpression(pattern: source)
    }
    
    private func runListDirectory(_ path: String) -> String {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else {
            return "Error listing directory '\(path)': no such directory"
        }
        guard !entries.isEmpty else { return "(empty directory)" }
        
        var lines: [String] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let fullPath = (path as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                lines.append("\(entry)/ (directory)")
            } else {
                let attributes = (try? fileManager.attributesOfItem(atPath: fullPath)) ?? [:]
                let size = (attributes[.size] as? Int) ?? 0
                lines.append("\(entry) (\(size) bytes)")
            }
        }
        return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
    }
}
