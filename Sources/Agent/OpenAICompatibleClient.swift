//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// OpenAICompatibleClient.swift
//

import Foundation
import Stores

/// Client for any local AI server that speaks the OpenAI-compatible
/// `/v1/chat/completions` dialect (mlx server, llama.cpp, LM Studio, ...).
/// Uses SSE streaming so answer and thinking tokens are delivered as they
/// are generated, keeping long turns alive and visible.
public struct OpenAICompatibleClient: LLMClient {
    private let endpoint: URL
    private let model: String
    private let session: URLSession
    private let debugLog: Bool
    private let debugLogDirectory: URL?

    // Global sequence so consecutive calls get consecutive, diffable filenames.
    // Shared across instances (there is one in practice) and kept off the
    // struct's value storage so the type stays Sendable.
    private static let debugLogLock = NSLock()
    // Access is guarded by debugLogLock; marked unsafe to opt out of the
    // global-mutable-state check.
    private static nonisolated(unsafe) var debugLogCounter = 0

    public init(
        endpoint: URL,
        model: String = "default",
        session: URLSession? = nil,
        debugLog: Bool = false
    ) {
        self.endpoint = endpoint
        self.model = model
        self.session = session ?? Self.makeSession()
        self.debugLog = debugLog
        self.debugLogDirectory = debugLog ? TerrapinPaths.logsDirectory : nil
    }

    public func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        slotId: Int?,
        onContent: @escaping @Sendable (String) -> Void,
        onThought: @escaping @Sendable (String) -> Void
    ) async throws -> LLMResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(
            ChatCompletionRequest(
                model: model,
                messages: messages,
                tools: tools,
                slotId: slotId
            )
        )

        if debugLog {
            Self.writeDebugLog(request.httpBody!, to: debugLogDirectory!)
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Task was cancelled (session/cancel); surface it as such so the
            // agent stops quietly instead of reporting a dropped connection.
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.badResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
            }
            throw LLMError.httpStatus(httpResponse.statusCode, body: body)
        }

        var content = ""
        var reasoning = ""
        var usage: LLMUsage?
        var toolCallFragments: [Int: AccumulatedToolCall] = [:]

        do {
            for try await line in bytes.lines {
                guard let chunk = Self.parseChunk(from: line) else { continue }

                // Servers that support stream_options.include_usage send the
                // token counts in the final chunk, after the last delta.
                if let chunkUsage = chunk.usage {
                    usage = LLMUsage(
                        promptTokens: chunkUsage.promptTokens ?? 0,
                        completionTokens: chunkUsage.completionTokens ?? 0,
                        cachedTokens: chunkUsage.promptTokensDetails?.cachedTokens
                    )
                }

                guard let delta = chunk.choices?.first?.delta else { continue }

                if let text = delta.content, !text.isEmpty {
                    content += text
                    onContent(text)
                }

                // Servers vary on the thinking key: mlx_lm/OpenAI use
                // "reasoning_content", some use "reasoning".
                if let thought = delta.reasoningContent ?? delta.reasoning,
                    !thought.isEmpty
                {
                    reasoning += thought
                    onThought(thought)
                }

                for fragment in delta.toolCalls ?? [] {
                    let index = fragment.index ?? 0
                    var accumulated = toolCallFragments[index] ?? AccumulatedToolCall()
                    if let id = fragment.id { accumulated.id = id }
                    if let name = fragment.function?.name {
                        accumulated.name += name
                    }
                    if let args = fragment.function?.arguments {
                        accumulated.arguments += args
                    }
                    toolCallFragments[index] = accumulated
                }
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw LLMError.streamInterrupted
        }

        let toolCalls = toolCallFragments.keys.sorted().compactMap { index -> ToolCall? in
            guard let fragment = toolCallFragments[index], !fragment.name.isEmpty else {
                return nil
            }
            return ToolCall(
                id: fragment.id.isEmpty ? "call_\(index)" : fragment.id,
                function: FunctionCall(
                    name: fragment.name,
                    arguments: fragment.arguments
                )
            )
        }

        guard !content.isEmpty || !toolCalls.isEmpty || !reasoning.isEmpty else {
            throw LLMError.badResponse
        }

        return LLMResponse(
            content: content.isEmpty ? nil : content,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            toolCalls: toolCalls,
            usage: usage
        )
    }

    // MARK: - SSE Parsing

    /// Decodes a single SSE line into its full chunk, if any. Usage lives
    /// outside the delta, so the caller needs the whole chunk.
    private static func parseChunk(from line: String) -> StreamChunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return nil }

        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StreamChunk.self, from: data)
    }

    // MARK: - Request / Response Models

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let tools: [ToolDefinition]
        let toolChoice: String
        let stream: Bool
        // Asks the server to include the token usage in the final stream
        // chunk. Servers that don't support the field ignore it.
        let streamOptions: StreamOptions
        // llama.cpp: pins the request to a server slot so its KV cache is
        // reused when the prompt extends the previous one. Omitted when nil.
        let slotId: Int?

        init(
            model: String,
            messages: [ChatMessage],
            tools: [ToolDefinition],
            slotId: Int?
        ) {
            self.model = model
            self.messages = messages
            self.tools = tools
            self.toolChoice = "auto"
            self.stream = true
            self.streamOptions = StreamOptions(includeUsage: true)
            self.slotId = slotId
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, tools, stream
            case toolChoice = "tool_choice"
            case streamOptions = "stream_options"
            case slotId = "slot_id"
        }
    }

    private struct StreamOptions: Encodable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCallFragment: Decodable {
                    struct FunctionFragment: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int?
                    let id: String?
                    let function: FunctionFragment?
                }

                let content: String?
                let reasoningContent: String?
                let reasoning: String?
                let toolCalls: [ToolCallFragment]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                    case reasoning
                    case toolCalls = "tool_calls"
                }
            }
            let delta: Delta
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        // Optional: the final usage chunk (choices omitted or empty) must
        // still decode, and servers vary on how strictly they follow the spec.
        let choices: [Choice]?
        let usage: Usage?

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let promptTokensDetails: Details?

            struct Details: Decodable {
                let cachedTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case cachedTokens = "cached_tokens"
                }
            }

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case promptTokensDetails = "prompt_tokens_details"
            }
        }
    }

    /// Accumulates the incremental tool-call fragments a server sends across
    /// multiple SSE chunks (id, name, and arguments arrive in pieces).
    private struct AccumulatedToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    // MARK: - Debug Logging

    /// Writes the exact request body to a numbered file so consecutive calls
    /// can be diffed to find where the prompt prefix diverges. Pretty-printed
    /// with sorted keys so the only diffs are real content changes.
    private static func writeDebugLog(_ body: Data, to directory: URL) {
        debugLogLock.lock()
        defer { debugLogLock.unlock() }
        debugLogCounter += 1
        let index = debugLogCounter

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var payload = body
        if
            let object = try? JSONSerialization.jsonObject(with: body),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        {
            payload = pretty
        }

        let url = directory.appendingPathComponent(String(format: "%04d.json", index))
        try? payload.write(to: url)
    }

    // MARK: - Session

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // Idle timeout: fires only if NO bytes (including thinking tokens)
        // arrive within this window. Active thinking keeps the turn alive.
        config.timeoutIntervalForRequest = 5 * 60.0
        // No practical total cap: a turn may run for hours while streaming.
        config.timeoutIntervalForResource = 24 * 60 * 60.0
        return URLSession(configuration: config)
    }
}
