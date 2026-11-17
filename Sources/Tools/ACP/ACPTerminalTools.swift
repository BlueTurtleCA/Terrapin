//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPTerminalTools.swift
//

import Foundation

/// The terminal tools: run_command and the terminal_create / terminal_output /
/// terminal_wait_for_exit / terminal_kill / terminal_release pair, plus the
/// per-session terminal tracking table helpers.
extension ACPClientTools {
    private enum CreatedTerminal {
        case id(String)
        case failure(String)
    }

    private func createTerminal(args: [String: Any], cwd: String, sessionId: String, callId: String) async -> CreatedTerminal {
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
        } else if Self.posixShells.contains(command),
                  let first = commandArgs.first,
                  !first.hasPrefix("-") {
            // The model invoked a POSIX shell directly but left the command
            // lines in `args` without a -c flag (e.g. /bin/sh + ["echo hi",
            // "sleep 3"]). Passed through as-is, the shell would look for a
            // script file named after the first arg and exit immediately.
            // Re-express the args as a single -c script, joining the
            // statements with `; ` so each one runs.
            finalArgs = ["-c", commandArgs.joined(separator: "; ")]
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
            trackTerminal(terminalId, callId: callId, in: sessionId)
            return .id(terminalId)
        case .error(let message):
            return .failure("Error creating terminal: \(message)")
        }
    }

    func runCommand(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to run_command"
        }

        let callId = "call_" + UUID().uuidString
        let title = Self.commandTitle(args)

        let created = await createTerminal(args: args, cwd: cwd, sessionId: sessionId, callId: callId)
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
        _ = untrackTerminal(terminalId, in: sessionId)

        Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: finalStatus, sendJSON: sendJSON)

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? statusLine : statusLine + "\n" + trimmed
    }

    func createTerminalTool(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to terminal_create"
        }

        let callId = "call_" + UUID().uuidString
        let title = Self.commandTitle(args)

        switch await createTerminal(args: args, cwd: cwd, sessionId: sessionId, callId: callId) {
        case .id(let terminalId):
            // Embed the terminal in the tool call so the client displays
            // live output for the lifetime of the terminal. The call is
            // left in_progress on purpose: Xcode ties the terminal's
            // lifetime to the tool call that embeds it and tears the
            // terminal down as soon as that call completes, so completion
            // is deferred to terminal_release (or the session cleanup).
            Self.sendToolCall(
                sessionId: sessionId,
                callId: callId,
                name: "terminal_create",
                title: title,
                status: "in_progress",
                terminalId: terminalId,
                sendJSON: sendJSON
            )
            return "Terminal created: \(terminalId)"
        case .failure(let message):
            Self.sendToolCall(sessionId: sessionId, callId: callId, name: "terminal_create", title: title, status: "in_progress", sendJSON: sendJSON)
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return message
        }
    }

    func terminalOutput(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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

    func terminalWaitForExit(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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

    func terminalKill(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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

    func terminalRelease(argsJSON: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
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
            let tracked = untrackTerminal(terminalId, in: sessionId)
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "completed", sendJSON: sendJSON)
            // The terminal_create call that embeds this terminal has been
            // in_progress since it was created; close it out now that the
            // terminal is released.
            if let tracked {
                Self.sendToolCallUpdate(
                    sessionId: sessionId,
                    callId: tracked.callId,
                    status: "completed",
                    sendJSON: sendJSON
                )
            }
            return "Terminal \(terminalId) released."
        case .error(let message):
            Self.sendToolCallUpdate(sessionId: sessionId, callId: callId, status: "failed", sendJSON: sendJSON)
            return "Error releasing terminal: \(message)"
        }
    }
    
    private func trackTerminal(_ terminalId: String, callId: String, in sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        activeTerminals[sessionId, default: [:]][terminalId] = TrackedTerminal(callId: callId)
    }
    
    /// Removes the terminal from the tracking table and returns the tool
    /// call that embedded it, so the releaser can close that call out.
    private func untrackTerminal(_ terminalId: String, in sessionId: String) -> TrackedTerminal? {
        lock.lock()
        defer { lock.unlock() }
        let tracked = activeTerminals[sessionId]?.removeValue(forKey: terminalId)
        if activeTerminals[sessionId]?.isEmpty == true {
            activeTerminals[sessionId] = nil
        }
        return tracked
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
}
