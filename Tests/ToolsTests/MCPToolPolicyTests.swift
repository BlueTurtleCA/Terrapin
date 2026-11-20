//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// MCPToolPolicyTests.swift
//

import Foundation
import Logger
import Stores
import Testing

@testable import Tools

private struct NoOpLogger: Loggable {
    func debug(_ message: String) {}
}

/// Records the tool_call (kind, title) pairs and tool_call_update statuses
/// arriving via sendJSON.
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [(kind: String, title: String)] = []
    private var recordedStatuses: [String] = []

    func record(_ json: [String: Any]) {
        let update = (json["params"] as? [String: Any])?["update"] as? [String: Any]
        guard let sessionUpdate = update?["sessionUpdate"] as? String else { return }
        lock.lock()
        defer { lock.unlock() }
        switch sessionUpdate {
        case "tool_call":
            recordedCalls.append((
                kind: update?["kind"] as? String ?? "",
                title: update?["title"] as? String ?? ""
            ))
        case "tool_call_update":
            recordedStatuses.append(update?["status"] as? String ?? "")
        default:
            break
        }
    }

    var calls: [(kind: String, title: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    var statuses: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStatuses
    }
}

@Suite("MCP tool policy")
struct MCPToolPolicyTests {
    // MARK: - Allowlist

    @Test("a nil allowlist offers every tool")
    func nilAllowlistOffersEverything() {
        #expect(MCPToolPolicy.unrestricted.isAllowed("AnythingAtAll"))
    }

    @Test("an allowlist offers only its members")
    func allowlistFiltersTools() {
        let policy = MCPToolPolicy(allowlist: ["BuildProject", "RunAllTests"])
        #expect(policy.isAllowed("BuildProject"))
        #expect(policy.isAllowed("RunAllTests"))
        #expect(!policy.isAllowed("XcodeRead"))
    }

    // MARK: - Categories

    @Test("unknown tools default to execute <name>")
    func categoryDefaults() {
        #expect(
            MCPToolPolicy().category(for: "RunAllTests")
                == MCPToolCategory(kind: "execute", title: "RunAllTests")
        )
    }

    @Test("categories override the default presentation")
    func categoryOverrides() {
        let policy = MCPToolPolicy(
            categories: [
                "GetBuildLog": .init(kind: "other", title: "Fetching Xcode Diagnostics with GetBuildLog"),
            ]
        )
        #expect(
            policy.category(for: "GetBuildLog")
                == MCPToolCategory(kind: "other", title: "Fetching Xcode Diagnostics with GetBuildLog")
        )
        #expect(
            policy.category(for: "BuildProject")
                == MCPToolCategory(kind: "execute", title: "BuildProject")
        )
    }

    // MARK: - Per-client policies

    @Test("the Xcode policy mirrors the old bridge allowlist")
    func xcodePolicy() {
        let policy = MCPToolPolicy.forClient(.xcode)
        #expect(policy.isAllowed("BuildProject"))
        #expect(policy.isAllowed("GetBuildLog"))
        #expect(policy.isAllowed("XcodeListNavigatorIssues"))
        #expect(policy.isAllowed("XcodeRefreshCodeIssuesInFile"))
        #expect(policy.isAllowed("RunSomeTests"))
        #expect(policy.isAllowed("RunAllTests"))
        #expect(policy.isAllowed("RunCodeSnippet"))
        #expect(policy.isAllowed("RenderPreview"))
        #expect(policy.isAllowed("DocumentationSearch"))
        #expect(policy.isAllowed("XcodeOpenWorkspace"))
        // The file tools stay native; the model is not offered the IDE's
        // file tools directly.
        #expect(!policy.isAllowed("XcodeRead"))
        #expect(!policy.isAllowed("XcodeWrite"))
        #expect(policy.category(for: "DocumentationSearch").title == "Searching Apple Documentation")
        #expect(policy.category(for: "DocumentationSearch").kind == "other")
        #expect(
            policy.category(for: "RenderPreview")
                == MCPToolCategory(kind: "other", title: "Rendering SwiftUI Preview")
        )
        #expect(
            policy.category(for: "BuildProject")
                == MCPToolCategory(kind: "execute", title: "BuildProject")
        )
    }

    @Test("the Android Studio policy mirrors the ide-tools bridge toolset")
    func androidPolicy() {
        let policy = MCPToolPolicy.forClient(.androidstudio)
        #expect(policy.isAllowed("studio_find_files"))
        #expect(policy.isAllowed("studio_find_declaration"))
        #expect(policy.isAllowed("studio_find_usages"))
        #expect(policy.isAllowed("studio_gradle_build"))
        #expect(policy.isAllowed("studio_run_shell_command"))
        #expect(policy.isAllowed("studio_deploy"))
        #expect(policy.isAllowed("studio_read_logcat"))
        #expect(policy.isAllowed("studio_render_compose_preview"))
        #expect(policy.isAllowed("studio_ask_user"))
        #expect(policy.isAllowed("studio_search_android_docs"))
        #expect(policy.isAllowed("studio_fetch_android_docs"))
        #expect(policy.isAllowed("studio_gradle_sync"))
        #expect(!policy.isAllowed("someOtherTool"))
        #expect(
            policy.category(for: "someTool")
                == MCPToolCategory(kind: "execute", title: "someTool")
        )
    }

    @Test("generic clients get the unrestricted policy")
    func genericPolicy() {
        #expect(MCPToolPolicy.forClient(.generic(name: "Zed")).isAllowed("anything"))
    }

    // MARK: - Vision gating

    @Test("vision-gated tools are withheld only when the model cannot see")
    func visionGating() {
        let xcode = MCPToolPolicy.forClient(.xcode)
        // Explicitly no vision: the preview tool (an image) is withheld,
        // the rest of the allowlist is untouched.
        #expect(!xcode.isAllowed("RenderPreview", supportsVision: false))
        #expect(xcode.isAllowed("BuildProject", supportsVision: false))
        // Vision or unknown (server did not report it): everything stays.
        #expect(xcode.isAllowed("RenderPreview", supportsVision: true))
        #expect(xcode.isAllowed("RenderPreview"))

        let android = MCPToolPolicy.forClient(.androidstudio)
        #expect(!android.isAllowed("studio_render_compose_preview", supportsVision: false))
        #expect(android.isAllowed("studio_gradle_build", supportsVision: false))
        #expect(android.isAllowed("studio_render_compose_preview"))
    }

    // MARK: - Client integration (stdio)

    /// A fake stdio MCP server advertising two tools and answering every
    /// tools/call with "ok".
    private static let fakeServerScript = """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1001,"result":{"protocolVersion":"2025-03-26"}}'
          ;;
        *'"method":"tools/list"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1002,"result":{"tools":[{"name":"BuildProject","description":"builds","inputSchema":{"type":"object","properties":{}}},{"name":"XcodeRead","description":"reads","inputSchema":{"type":"object","properties":{}}}]}}'
          ;;
        *'"method":"tools/call"'*)
          id=$(printf '%s' "$line" | sed -n 's/.*"id": *\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"ok"}]}}\\n' "$id"
          ;;
      esac
    done
    """

    @Test("definitions() applies the allowlist, routing does not")
    func allowlistAppliesToDefinitionsNotRouting() async throws {
        let client = MCPStdioClient(
            descriptor: MCPServerDescriptor(
                name: "fake",
                command: "/bin/sh",
                args: ["-c", Self.fakeServerScript]
            ),
            logger: NoOpLogger(),
            policy: MCPToolPolicy(
                allowlist: ["BuildProject"],
                categories: [
                    "BuildProject": .init(kind: "execute", title: "Building the project"),
                ]
            )
        )
        try await client.start()
        _ = await client.fetchTools()

        // The raw advertised list keeps every tool, so internal routing
        // (read_file → XcodeRead) still reaches XcodeRead.
        #expect(
            Set(await client.advertisedToolNames())
                == Set(["BuildProject", "XcodeRead"])
        )
        // The model is offered only the allowed tool.
        #expect(await client.definitions().map { $0.function.name } == ["BuildProject"])

        // execute() presents the call under the policy's category and the
        // invisible callTool() round-trip works for non-offered tools.
        let recorder = CallRecorder()
        _ = await client.execute(
            name: "BuildProject",
            argsJSON: "{}",
            cwd: "/tmp",
            sessionId: "s",
            sendJSON: recorder.record
        )
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.kind == "execute")
        #expect(recorder.calls.first?.title == "Building the project")
        #expect(recorder.statuses == ["completed"])
        #expect(await client.callTool(name: "XcodeRead", argsJSON: "{}") == "ok")

        await client.stop()
    }

    /// A fake stdio MCP server advertising an ordinary tool next to a
    /// vision-only one (its result is an image).
    private static let visionFakeServerScript = """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1001,"result":{"protocolVersion":"2025-03-26"}}'
          ;;
        *'"method":"tools/list"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1002,"result":{"tools":[{"name":"BuildProject","description":"builds","inputSchema":{"type":"object","properties":{}}},{"name":"RenderPreview","description":"renders","inputSchema":{"type":"object","properties":{}}}]}}'
          ;;
      esac
    done
    """

    @Test("definitions() withholds vision-gated tools for non-vision models")
    func visionGatedToolsWithheldFromDefinitions() async throws {
        let client = MCPStdioClient(
            descriptor: MCPServerDescriptor(
                name: "fake-vision",
                command: "/bin/sh",
                args: ["-c", Self.visionFakeServerScript]
            ),
            logger: NoOpLogger(),
            policy: MCPToolPolicy(
                allowlist: ["BuildProject", "RenderPreview"],
                visionRequired: ["RenderPreview"]
            ),
            supportsVision: false
        )
        try await client.start()
        _ = await client.fetchTools()

        // The raw advertised list keeps the gated tool, so internal routing
        // can still reach it.
        #expect(
            Set(await client.advertisedToolNames())
                == Set(["BuildProject", "RenderPreview"])
        )
        // The model is offered only the tool it can actually use.
        #expect(await client.definitions().map { $0.function.name } == ["BuildProject"])

        await client.stop()
    }
}
