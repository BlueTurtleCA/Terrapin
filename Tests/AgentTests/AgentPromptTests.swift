//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// AgentPromptTests.swift
//

import Foundation
import Testing
import Stores

@testable import Agent

// The test templates separate every placeholder with "|", so the built
// system prompt splits into [CWD, PLATFORM_INSTRUCTIONS, TERMINAL_TOOLS,
// NETWORK_STATUS, SKILLS, CUSTOM_INSTRUCTIONS].

@Suite("Agent system prompt")
struct AgentPromptTests {
    /// The system prompt the model saw on the first LLM call.
    private func systemPrompt(_ harness: AgentHarness) -> String {
        guard harness.llm.callCount > 0 else { return "" }
        return harness.llm.calls[0].messages.first?.content ?? ""
    }

    private func blocks(_ prompt: String) -> [String] {
        prompt.components(separatedBy: "|")
    }

    @Test("placeholders are substituted for a known client")
    func placeholdersSubstituted() async {
        let tool = testToolDefinition("run_command")
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            tools: [tool],
            skills: [testSkill]
        )
        harness.temp.writeFile("AGENTS.md", contents: "Always use tabs.")
        let recorder = Recorder()
        await harness.run(prompt: "hi", tools: [tool], recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts.count == 6)
        #expect(systemPrompt(harness).hasPrefix("XCODE "))
        #expect(parts[0] == "XCODE " + harness.cwd)
        #expect(parts[1].isEmpty) // no platform instructions in the harness
        #expect(parts[2].contains("### TERMINAL & SHELL COMMANDS"))
        #expect(parts[3].isEmpty) // online: no network status block
        #expect(parts[4].contains("### AVAILABLE SKILLS"))
        #expect(parts[4].contains("test-skill"))
        #expect(parts[5].contains("### PROJECT-SPECIFIC INSTRUCTIONS (AGENTS.MD)"))
        #expect(parts[5].contains("Always use tabs."))
    }

    @Test("platform instructions are substituted into the prompt")
    func platformInstructionsInjected() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            platformInstructions: "### PLATFORM: TestOS\nYou are running on TestOS."
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[1].contains("### PLATFORM: TestOS"))
        #expect(parts[1].contains("You are running on TestOS."))
    }

    @Test("the terminal block is omitted without run_command")
    func noTerminalBlock() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", tools: [testToolDefinition("other_tool")], recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[2].isEmpty)
    }

    @Test("no AGENTS.md means no custom instructions block")
    func noAgentsMd() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[5].isEmpty)
    }

    @Test("no skills means an empty skills block")
    func noSkills() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[4].isEmpty)
    }

    @Test("unknown clients fall back to the generic template")
    func genericFallback() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", client: .generic(name: "Zed"), recorder: recorder)

        #expect(systemPrompt(harness).hasPrefix("GENERIC "))
    }

    @Test("the androidstudio client selects its own template")
    func androidStudioTemplate() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", client: .androidstudio, recorder: recorder)

        #expect(systemPrompt(harness).hasPrefix("ANDROID "))
    }

    // Templates for the vision tests: every placeholder separated by "|", so
    // the built prompt splits into [CWD, NATIVE_TOOLS, VISION_STATUS].
    private let visionTemplates: [ClientKind: String] = [
        .xcode: "XCODE {{CWD}}|{{NATIVE_TOOLS}}|{{VISION_STATUS}}",
        .generic(name: "unknown"): "GENERIC {{CWD}}|{{NATIVE_TOOLS}}|{{VISION_STATUS}}",
    ]

    @Test("when the model cannot see, the prompt stops advertising image reads")
    func visionDisabledPrompt() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            templates: visionTemplates,
            supportsVision: false
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[1].contains("read_file (for reading text files from disk)"))
        #expect(parts[1].contains("you can see") == false)
        #expect(parts[2].contains("### VISION STATUS"))
        #expect(parts[2].contains("does not support vision"))
    }

    @Test("when the model can see, the prompt keeps the image wording")
    func visionEnabledPrompt() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            templates: visionTemplates,
            supportsVision: true
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[1].contains("images you can see"))
        #expect(parts[2].isEmpty)
    }

    @Test("when vision support is unknown, the prompt keeps the image wording")
    func visionUnknownPrompt() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            templates: visionTemplates
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[1].contains("images you can see"))
        #expect(parts[2].isEmpty)
    }
}
