//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ChatMessage.swift
//

import Foundation

/// An image attached to a chat message, base64-encoded. Used for tool
/// results that contain images (e.g. read_file on a PNG): the agent attaches
/// it to the tool-result message, and the OpenAI-compatible request encodes
/// it as an `image_url` content part with a data URL.
public struct ImageAttachment: Codable, Sendable, Equatable {
    /// MIME type, e.g. "image/png" or "image/jpeg".
    public let mimeType: String
    /// Base64-encoded image bytes.
    public let base64: String
    /// Where the image came from (usually a file path). Used for the
    /// persisted-history note; not sent to the model.
    public let source: String?

    public init(mimeType: String, base64: String, source: String? = nil) {
        self.mimeType = mimeType
        self.base64 = base64
        self.source = source
    }

    /// The data-URL form used in the `image_url` content part.
    public var dataURL: String {
        "data:\(mimeType);base64,\(base64)"
    }
}

/// One part of a multimodal message content, in the OpenAI-compatible
/// content-parts wire format (`{"type": "text", "text": ...}` or
/// `{"type": "image_url", "image_url": {"url": ...}}`).
struct ContentPart: Codable, Sendable {
    struct ImageURL: Codable, Sendable {
        let url: String
    }

    let type: String
    let text: String?
    let imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func textPart(_ text: String) -> ContentPart {
        ContentPart(type: "text", text: text, imageURL: nil)
    }

    static func imagePart(_ attachment: ImageAttachment) -> ContentPart {
        ContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: attachment.dataURL))
    }
}

public struct ChatMessage: Codable, Sendable {
    /// "system" | "user" | "assistant" | "tool"
    public let role: String
    public var content: String?
    /// The model's chain-of-thought (returned by some local servers, e.g.
    /// llama.cpp with `include_usage`/reasoning). Not sent back to the model.
    public var reasoning: String?
    /// Only for role "tool": the id of the ToolCall this message is the result of.
    public var toolCallId: String?
    /// Only for role "tool": the name of the tool that was called.
    public var name: String?
    /// Only for role "assistant": the ToolCalls the model requested.
    public var toolCalls: [ToolCall]?
    /// Image attachments for this message (e.g. an image read by read_file).
    /// When present, the message's `content` is sent to the model as an
    /// array of content parts (text + image_url) instead of a plain string.
    /// Images are never persisted to session files.
    public var images: [ImageAttachment]?

    private enum CodingKeys: String, CodingKey {
        case role, content, reasoning
        case toolCallId = "tool_call_id"
        case name
        case toolCalls = "tool_calls"
        case images
    }

    public init(
        role: String,
        content: String? = nil,
        reasoning: String? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        toolCalls: [ToolCall]? = nil,
        images: [ImageAttachment]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCallId = toolCallId
        self.name = name
        self.toolCalls = toolCalls
        self.images = images
    }

    /// Encodes the message for the model. Plain messages keep the compact
    /// string `content`; messages with images use the content-parts array
    /// (text part first, then one image_url part per attachment), which is
    /// the format the OpenAI chat completions API accepts for vision.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let images, !images.isEmpty {
            var parts: [ContentPart] = []
            if let content {
                parts.append(.textPart(content))
            }
            parts.append(contentsOf: images.map { .imagePart($0) })
            try container.encode(parts, forKey: .content)
        } else if let content {
            try container.encode(content, forKey: .content)
        }
        if let reasoning { try container.encode(reasoning, forKey: .reasoning) }
        if let toolCallId { try container.encode(toolCallId, forKey: .toolCallId) }
        if let name { try container.encode(name, forKey: .name) }
        if let toolCalls { try container.encode(toolCalls, forKey: .toolCalls) }
    }

    /// Decodes leniently: `content` may be a plain string or a content-parts
    /// array. If parts are stored, the text parts are kept and the image
    /// parts are dropped (images are not persisted; this only matters for
    /// hand-edited or foreign session files).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        if container.contains(.content) {
            do {
                content = try container.decode(String.self, forKey: .content)
            } catch {
                // Content stored as a content-parts array (text + image_url
                // parts): keep the text, drop the image parts.
                let parts = try container.decode([ContentPart].self, forKey: .content)
                let text = parts.compactMap { $0.text }.joined(separator: "\n")
                content = text.isEmpty ? nil : text
            }
        }
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        images = try container.decodeIfPresent([ImageAttachment].self, forKey: .images)
    }

    /// A copy of the message with its image attachments removed and a short
    /// note in their place, for persisted history. Session files are meant to
    /// stay small and text-only: a screenshot is rarely needed again, and
    /// re-sending it on every later turn would burn tokens.
    public func strippingImages() -> ChatMessage {
        guard let images, !images.isEmpty else { return self }
        var content = self.content ?? ""
        for image in images {
            let note = "[image of \(image.source ?? "unknown source") not persisted to history]"
            content += (content.isEmpty ? "" : "\n") + note
        }
        var copy = self
        copy.content = content
        copy.images = nil
        return copy
    }
}

public struct ToolCall: Codable, Sendable {
    public let id: String
    public let function: FunctionCall

    public init(id: String, function: FunctionCall) {
        self.id = id
        self.function = function
    }
}

public struct FunctionCall: Codable, Sendable {
    public let name: String
    /// Raw JSON object string, e.g. {"path": "foo.swift"}
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}
