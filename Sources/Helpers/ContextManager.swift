//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ContextResolver.swift
//

import Foundation
import Stores

public struct ContextManager {

    /// The token cost assumed for each attached image. The images the agent
    /// sends have a longest edge of at most 1568px, which vision tokenizers
    /// render as a small grid of tiles (typically around a thousand tokens).
    public static let imageTokenEstimate = 1200

    /// Estimates token count for a message list (approx. 1 token = 3.5
    /// characters for text, plus a fixed cost per attached image).
    public static func estimateTokenCount(_ history: [ChatMessage]) -> Int {
        var totalChars = 0
        var imageTokens = 0
        for msg in history {
            totalChars += msg.content?.count ?? 0
            totalChars += msg.reasoning?.count ?? 0
            imageTokens += (msg.images?.count ?? 0) * imageTokenEstimate
            if let toolCalls = msg.toolCalls {
                for call in toolCalls {
                    totalChars +=
                        call.function.name.count + call.function.arguments.count
                }
            }
        }
        return Int(Double(totalChars) / 3.5) + imageTokens
    }

    /// The outcome of a history compaction: the compacted message list plus
    /// stats describing what was dropped, for reporting to the client.
    public struct CompactionResult: Sendable {
        /// The history to use going forward (identical to the input when
        /// `compacted` is false).
        public let messages: [ChatMessage]
        /// Whether any original messages were dropped.
        public let compacted: Bool
        /// Number of original messages that were removed.
        public let messagesRemoved: Int
        /// Number of recent original messages kept in the window.
        public let messagesKept: Int
        /// Estimated token count of the history before compaction.
        public let tokensBefore: Int
        /// Estimated token count of the history after compaction.
        public let tokensAfter: Int
    }

    /// Safely truncates middle messages when token limit is approached.
    /// `knownTokens` is the caller's best-known actual token count for
    /// `history` (server-measured occupancy plus estimated additions since);
    /// when provided it replaces the character-based estimate for the
    /// threshold decision.
    public static func compactHistory(
        _ history: [ChatMessage],
        maxTokens: Int = 16384,  // Set to your model's context size (e.g. 8192, 16384, 32768)
        targetBudgetRatio: Double = 0.90,  // Compact when usage exceeds 90% of max context
        force: Bool = false,  // Bypass the token threshold (manual /compact)
        knownTokens: Int? = nil
    ) -> CompactionResult {
        let currentTokens = knownTokens ?? estimateTokenCount(history)
        let tokenLimit = Int(Double(maxTokens) * targetBudgetRatio)

        // Return untouched if within context budget. A forced compaction
        // bypasses the token threshold but still needs more than four
        // messages, since the recent window would keep everything else.
        guard history.count > 4, force || currentTokens > tokenLimit else {
            return CompactionResult(
                messages: history,
                compacted: false,
                messagesRemoved: 0,
                messagesKept: history.count,
                tokensBefore: currentTokens,
                tokensAfter: currentTokens
            )
        }

        let systemMessage = history.first { $0.role == "system" }
        var compacted: [ChatMessage] = []

        if let systemMessage {
            compacted.append(systemMessage)
        }

        // Add a compaction notice marker
        compacted.append(
            ChatMessage(
                role: "user",
                content:
                    "System Note: Older conversation turns were compacted to stay within the context window limit."
            )
        )
        compacted.append(
            ChatMessage(
                role: "assistant",
                content:
                    "Understood. I will continue focusing on your latest commands using the existing workspace state."
            )
        )

        // Keep the most recent messages that fit within a token budget, so a
        // single huge tool result can't blow the window and small turns keep
        // more context than a fixed message count would allow.
        let keepBudget = Int(Double(maxTokens) * 0.50)
        var recentMessages: [ChatMessage] = []
        var usedTokens = 0
        for message in history.reversed() {
            let messageTokens = estimateTokenCount([message])
            if !recentMessages.isEmpty, usedTokens + messageTokens > keepBudget {
                break
            }
            recentMessages.insert(message, at: 0)
            usedTokens += messageTokens
        }

        // Ensure we don't start recent history with an orphaned tool response
        while let first = recentMessages.first, first.role == "tool" {
            recentMessages.removeFirst()
        }

        compacted.append(contentsOf: recentMessages)

        // Count the original messages that survived: the recent window, plus
        // the system message when it was prepended rather than kept in the
        // window (a mid-history system message can be in both).
        var retained = recentMessages.count
        if systemMessage != nil,
            !recentMessages.contains(where: { $0.role == "system" })
        {
            retained += 1
        }

        return CompactionResult(
            messages: compacted,
            compacted: true,
            messagesRemoved: history.count - retained,
            messagesKept: recentMessages.count,
            tokensBefore: currentTokens,
            tokensAfter: estimateTokenCount(compacted)
        )
    }

    /// What the AI server reports about the loaded model (from its
    /// `/v1/models` endpoint), when it reports anything.
    public struct ModelInfo: Sendable {
        /// The server's reported context window, when it exposes one.
        public let contextWindow: Int?
        /// The server's explicit statement about the model's vision support
        /// (e.g. Splash's `"vision"` flag or an `"input_modalities"` list).
        /// Nil when the server does not report it.
        public let supportsVision: Bool?

        public init(contextWindow: Int?, supportsVision: Bool?) {
            self.contextWindow = contextWindow
            self.supportsVision = supportsVision
        }
    }

    /// Queries the AI server's endpoints to retrieve what the loaded model
    /// reports (context window and, when the server says, vision support).
    public static func resolveModelInfo(
        _ endpoint: String
    ) async -> ModelInfo {
        await resolveModelInfo(endpoint) { url in
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
    }

    /// Testable variant of ``resolveModelInfo(_:)`` with an injectable fetcher.
    static func resolveModelInfo(
        _ endpoint: String,
        fetch: @Sendable (URL) async throws -> Data
    ) async -> ModelInfo {
        let candidateURLs = [
            "\(endpoint)/api/v1/models",
            "\(endpoint)/v1/models",
        ].compactMap { URL(string: $0) }

        // The context window may come from a later URL when the first answer
        // lacks it (the original resolveContextWindow behavior); the vision
        // flag is taken from the first response that identifies the model.
        var vision: Bool?
        for url in candidateURLs {
            guard let data = try? await fetch(url),
                let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let models = json["data"] as? [[String: Any]],
                let activeModel = models.first(where: {
                    ($0["state"] as? String) == "loaded"
                }) ?? models.first
            else {
                continue
            }

            if vision == nil {
                vision = Self.supportsVision(of: activeModel)
            }

            if let ctx = Self.contextWindow(of: activeModel) {
                return ModelInfo(contextWindow: ctx, supportsVision: vision)
            }
        }

        // Conservative fallback if metadata is unavailable
        return ModelInfo(contextWindow: nil, supportsVision: vision)
    }

    /// Queries the AI server's endpoints to retrieve the loaded model's context window
    public static func resolveContextWindow(
        _ endpoint: String
    ) async -> Int {
        (await resolveModelInfo(endpoint)).contextWindow ?? 16384
    }

    /// Testable variant of ``resolveContextWindow(_:)`` with an injectable fetcher.
    static func resolveContextWindow(
        _ endpoint: String,
        fetch: @Sendable (URL) async throws -> Data
    ) async -> Int {
        (await resolveModelInfo(endpoint, fetch: fetch)).contextWindow ?? 16384
    }

    /// The context window a model entry reports, checking the key variants
    /// different servers use.
    private static func contextWindow(of model: [String: Any]) -> Int? {
        // llama.cpp reports the context length inside a "meta" object, and
        // the exact key varies by version:
        //   new: data[0].meta.n_ctx
        //   old: data[0].meta.model_info.context_length
        // Check "meta" first so we don't silently fall back to 16384 (which
        // would make compaction fire every turn and destroy KV prefix reuse).
        if let meta = model["meta"] as? [String: Any] {
            if let ctxLen = meta["n_ctx"] as? Int {
                return ctxLen
            }
            if let modelInfo = meta["model_info"] as? [String: Any],
                let ctxLen = modelInfo["context_length"] as? Int
            {
                return ctxLen
            }
            if let ctxLen = meta["context_length"] as? Int {
                return ctxLen
            }
        }

        // 1. Check direct server property
        if let maxCtx = model["max_context_length"] as? Int {
            return maxCtx
        }

        // 2. Some servers expose model_info at the top level
        if let modelInfo = model["model_info"] as? [String: Any],
            let ctxLen = modelInfo["context_length"] as? Int
        {
            return ctxLen
        }

        // 3. Check active instance config (v1 REST API)
        if let instances = model["loaded_instances"] as? [[String: Any]],
            let config = instances.first?["config"] as? [String: Any],
            let ctxLen = config["context_length"] as? Int
        {
            return ctxLen
        }

        // 4. Check standard fallback property
        return model["context_length"] as? Int
    }

    /// Whether a model entry says the model can accept images. Most
    /// OpenAI-compatible servers (llama.cpp, LM Studio, ...) don't report it
    /// at all — that is the `nil` case; only servers that state it explicitly
    /// (e.g. Splash's `"vision"` flag, or an `"input_modalities"` list)
    /// change the answer.
    private static func supportsVision(of model: [String: Any]) -> Bool? {
        if let vision = model["vision"] as? Bool {
            return vision
        }
        if let modalities = model["input_modalities"] as? [String] {
            return modalities.contains("image")
        }
        return nil
    }
}
