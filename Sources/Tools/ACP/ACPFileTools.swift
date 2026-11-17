//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPFileTools.swift
//

import Foundation
import Stores

/// The filesystem tools: read_file, write_file, edit_file, move_file,
/// delete_file and list_directory, with their local-disk fallbacks.
extension ACPClientTools {
    enum ACPError: Error {
        case message(String)
    }

    func readTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> ToolResult {
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
                    // ACP tool-call content can carry standard content blocks,
                    // including images. Without the image block the client
                    // only ever sees "Reading foo.png" and the picture never
                    // reaches the UI, so send it with the completion.
                    Self.sendToolCallUpdate(
                        sessionId: sessionId,
                        callId: callId,
                        status: "completed",
                        content: [
                            [
                                "type": "content",
                                "content": [
                                    "type": "text",
                                    "text": "Image of '\(path)' (\(format), \(width)x\(height), \(sizeKB) KB)."
                                ]
                            ],
                            [
                                "type": "content",
                                "content": [
                                    "type": "image",
                                    "mimeType": attachment.mimeType,
                                    "data": attachment.base64
                                ]
                            ]
                        ],
                        sendJSON: sendJSON
                    )
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
    
    func writeTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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
    
    func editTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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

    func moveFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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
    
    func deleteFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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
    
    func listDirectory(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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
