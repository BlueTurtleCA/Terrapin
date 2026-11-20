//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// MCPToolPolicy.swift
//

import Foundation
import Stores

/// The presentation of one MCP tool call in the client UI: the ACP
/// `tool_call` `kind` (read, edit, execute, search, fetch, think, other)
/// and the human-facing `title`.
public struct MCPToolCategory: Sendable, Equatable {
    public let kind: String
    public let title: String

    public init(kind: String, title: String) {
        self.kind = kind
        self.title = title
    }
}

/// The per-client policy for the MCP servers the ACP client declares for
/// a session: which of the server's advertised tools the model is offered
/// (the allowlist, further narrowed by the vision-required set for models
/// that cannot see) and how each tool call is presented to the client (the
/// categories).
///
/// The policy is attached to the MCP client at construction time. The
/// allowlist only narrows what the model can call directly: the client
/// keeps the server's raw advertised tool list, so internal routing (e.g.
/// read_file → XcodeRead) can still reach tools the model is not offered.
public struct MCPToolPolicy: Sendable {
    /// The tool names the model is offered; `nil` offers every advertised
    /// tool.
    public let allowlist: Set<String>?
    /// Tool names that only make sense to a model that can see images
    /// (e.g. RenderPreview, which returns a UI snapshot). These are withheld
    /// from the model when the server says the model does not support
    /// vision; a server that does not report vision keeps them.
    public let visionRequired: Set<String>
    /// Presentation overrides per tool name; tools without an entry fall
    /// back to `("execute", <name>)`.
    public let categories: [String: MCPToolCategory]

    public init(
        allowlist: Set<String>? = nil,
        visionRequired: Set<String> = [],
        categories: [String: MCPToolCategory] = [:]
    ) {
        self.allowlist = allowlist
        self.visionRequired = visionRequired
        self.categories = categories
    }

    /// Whether `name` is offered to the model. `supportsVision` is the
    /// server's statement about the model (nil when it does not report it);
    /// vision-gated tools are withheld only when it is explicitly false.
    public func isAllowed(_ name: String, supportsVision: Bool? = nil) -> Bool {
        if supportsVision == false, visionRequired.contains(name) {
            return false
        }
        guard let allowlist else { return true }
        return allowlist.contains(name)
    }

    /// The (kind, title) a call of `name` is presented under.
    public func category(for name: String) -> MCPToolCategory {
        categories[name] ?? MCPToolCategory(kind: "execute", title: name)
    }
}

public extension MCPToolPolicy {
    /// The permissive policy: every advertised tool is offered, and every
    /// call is presented as `execute <name>`.
    static let unrestricted = MCPToolPolicy()

    /// The policy for the connected ACP client.
    static func forClient(_ client: ClientKind) -> MCPToolPolicy {
        switch client {
        case .xcode:
            .xcode
        case .androidstudio:
            .androidStudio
        case .generic:
            .unrestricted
        }
    }

    /// Xcode's own MCP server: the model is offered the build, test,
    /// diagnostic, and documentation tools, each with its presentation.
    /// File access stays with the native ACP file tools, which route
    /// through the IDE's Xcode* tools internally. RenderPreview's output is
    /// a UI snapshot image, so it is withheld from non-vision models.
    static let xcode = MCPToolPolicy(
        allowlist: [
            "BuildProject",
            "GetBuildLog",
            "XcodeListNavigatorIssues",
            "XcodeRefreshCodeIssuesInFile",
            "RunSomeTests",
            "RunAllTests",
            "RunCodeSnippet",
            "RenderPreview",
            "DocumentationSearch",
            "XcodeOpenWorkspace",
        ],
        visionRequired: [
            "RenderPreview",
        ],
        categories: [
            // Build, test, and workspace tools keep the ("execute", <name>)
            // default presentation; these entries only override it.
            "DocumentationSearch": .init(
                kind: "other",
                title: "Searching Apple Documentation"
            ),
            "GetBuildLog": .init(
                kind: "other",
                title: "Fetching Xcode Diagnostics with GetBuildLog"
            ),
            "XcodeListNavigatorIssues": .init(
                kind: "other",
                title: "Fetching Xcode Diagnostics with XcodeListNavigatorIssues"
            ),
            "XcodeRefreshCodeIssuesInFile": .init(
                kind: "other",
                title: "Refreshing Code Issues"
            ),
            "RenderPreview": .init(
                kind: "other",
                title: "Rendering SwiftUI Preview"
            ),
        ]
    )

    /// Android Studio's "ide-tools" bridge: the pinned bridge toolset is
    /// offered. studio_render_compose_preview's output is a rendered
    /// preview image, so it is withheld from non-vision models.
    static let androidStudio = MCPToolPolicy(
        allowlist: [
            "studio_find_files",
            "studio_find_declaration",
            "studio_find_usages",
            "studio_gradle_build",
            "studio_run_shell_command",
            "studio_deploy",
            "studio_read_logcat",
            "studio_render_compose_preview",
            "studio_ask_user",
            "studio_search_android_docs",
            "studio_fetch_android_docs",
            "studio_gradle_sync"
        ],
        visionRequired: [
            "studio_render_compose_preview",
        ],
        categories: [
            // Build, test, and workspace tools keep the ("execute", <name>)
            // default presentation; these entries only override it.
            "studio_find_files": .init(
                kind: "search",
                title: "Searching for Files"
            ),
            "studio_find_declaration": .init(
                kind: "search",
                title: "Finding Declaration"
            ),
            "studio_find_usages": .init(
                kind: "search",
                title: "Finding Usages of Property or Class"
            ),
            "studio_read_logcat": .init(
                kind: "read",
                title: "Reading Logcat for More Details"
            ),
            "studio_render_compose_preview": .init(
                kind: "other",
                title: "Rendering Compose Preview"
            ),
            "studio_ask_user": .init(
                kind: "other",
                title: "Asking User for Clarification"
            ),
            "studio_search_android_docs": .init(
                kind: "search",
                title: "Finding Relevant Android Docs"
            ),
            "studio_fetch_android_docs": .init(
                kind: "fetch",
                title: "Fetching Current Android Docs"
            ),
        ]
    )
}
