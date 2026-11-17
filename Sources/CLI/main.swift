//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// main.swift
//

import Agent
import Foundation
import Helpers
import Logger
import Stores
import Tools

// 1. Load runtime configuration (CLI args / env vars)
let config = Config.load()

// Start network monitoring so web tools can fail fast when the machine is
// offline (e.g. Wi-Fi shut off) instead of waiting for a request timeout.
await NetworkMonitor.shared.start()

let logger = OSLogger()
let sessionStore = SessionStore(logger: logger)

// Remove session files that haven't been updated within the retention
// period (the same startup sweep Claude Code performs).
await sessionStore.cleanupStaleSessions()

// 2. Create the native Xcode MCP bridge client. It is started lazily by the
//    ACP server once the connecting client identifies itself as Xcode.
let mcpClient = XcodeMCPBridgeClient(logger, debugLog: config.debugLog)

// 3. Register the client-agnostic tool providers (built-in web tools +
//    native ACP client tools). The Xcode MCP bridge is added to the registry
//    by the ACP server after client detection.
let clientChannel = ClientChannel()

// Ask the server what it says about the loaded model: the context window and,
// when the server states it, whether the model can see images. The vision
// flag gates image reads so the model is not told it can view files it
// cannot.
let modelInfo = await ContextManager.resolveModelInfo(
    config.serverURL.absoluteString
)
let clientTools = ACPClientTools(
    clientChannel: clientChannel,
    xcodeBridge: mcpClient,
    supportsVision: modelInfo.supportsVision
)

// Skill discovery: project + user + extra + bundled skills. The same
// closure feeds the prompt catalog and the use_skill tool so the two
// always agree.
let skillCatalog: @Sendable (String) -> SkillCatalog = { cwd in
    SkillCatalog.discover(
        cwd: cwd,
        extraDirectories: config.skillDirectories,
        bundledSkillFiles: bundledSkillFiles()
    )
}

let toolRegistry = ToolRegistry([WebTools(), clientTools, SkillTools(catalog: skillCatalog)])

let contextWindow: Int
if let override = config.contextWindowOverride {
    contextWindow = override
} else {
    contextWindow = modelInfo.contextWindow ?? 16384
}
logger.debug("Using context window of: \(contextWindow)")
switch modelInfo.supportsVision {
case true:
    logger.debug("Model supports vision: image reads enabled")
case false:
    logger.debug("Model does not support vision: image reads disabled")
case nil:
    logger.debug("Server did not report vision support: image reads enabled (unknown)")
}
if config.debugLog {
    logger.debug("Debug logging enabled: LLM request bodies + Xcode MCP bridge calls -> ~/.terrapin/logs/")
}

// 4. Wire up the agent
let agent = Agent(
    llmClient: OpenAICompatibleClient(
        endpoint: config.chatCompletionsURL,
        model: config.model,
        debugLog: config.debugLog
    ),
    toolRegistry: toolRegistry,
    sessionStore: sessionStore,
    contextWindow: contextWindow,
    systemPromptTemplates: loadSystemPromptTemplates(),
    platformInstructions: loadPlatformInstructions(),
    skillCatalog: skillCatalog,
    logger: logger,
    slotCount: config.slots,
    supportsVision: modelInfo.supportsVision
)

// 5. Serve ACP over stdin/stdout
let server = ACPServer(
    agent: agent,
    sessionStore: sessionStore,
    toolRegistry: toolRegistry,
    xcodeBridge: mcpClient,
    clientChannel: clientChannel,
    clientTools: clientTools,
    defaultClient: config.defaultClient,
    debugLog: config.debugLog,
    logger: logger
)
logger.debug("=== Swift ACP Agent Started with Tool Calling ===")
await server.run()

// MARK: - System Prompt Templates

/// Loads the bundled system prompt templates (one per client kind) from the
/// compiled resources.
func loadSystemPromptTemplates() -> [ClientKind: String] {
    func load(_ name: String) -> String {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "md"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            fatalError("Failed to load bundled system prompt template \(name).md")
        }
        return contents
    }
    return [
        .xcode: load("system_prompt_xcode"),
        .generic(name: "unknown"): load("system_prompt_generic"),
        .androidstudio: load("system_prompt_androidstudio"),
    ]
}

/// Loads the bundled platform instruction block for the current operating
/// system. The files are plain markdown next to the system prompt templates
/// so they can be edited without touching code.
func loadPlatformInstructions() -> String {
    let name: String
    #if os(macOS)
    name = "platform_instructions_mac"
    #elseif os(Windows)
    name = "platform_instructions_windows"
    #elseif os(Linux)
    name = "platform_instructions_linux"
    #else
    return ""
    #endif
    guard
        let url = Bundle.module.url(forResource: name, withExtension: "md"),
        let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
        fatalError("Failed to load bundled platform instructions \(name).md")
    }
    return contents
}

/// Resolves the bundled skill files from the compiled resources. The build
/// system flattens package resource directories into the bundle root, so
/// each bundled skill is a uniquely named `.md` file (e.g. `git-commit.md`);
/// two skills may not share a file name.
func bundledSkillFiles() -> [URL] {
    // The platform instruction files are also bundled .md files at the root,
    // but they are prompt blocks, not skills.
    var files = (Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? [])
        .filter { !$0.lastPathComponent.hasPrefix("platform_instructions_") }
    // Some toolchains preserve the source layout (skills/*.md) instead of
    // flattening; pick those up too.
    if let nested = Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: "skills") {
        files.append(contentsOf: nested)
    }
    return files
}
