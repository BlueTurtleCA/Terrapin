//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ImageSupport.swift
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Stores

/// Reads image files for the model: classifies the file type from its
/// leading bytes (no extension guessing), downsamples it, and re-encodes it
/// so the base64 payload stays small enough for a local vision model's
/// context window.
public enum ImageSupport {
    /// Longest edge the model will see. Vision tokenizers tile the image, so
    /// capping it keeps a typical image to roughly a thousand or two tokens.
    public static let maxEdge = 1568

    /// Files larger than this are rejected instead of decoded.
    public static let maxFileBytes = 25 * 1024 * 1024

    /// Encoded payloads larger than this are re-encoded (lower JPEG quality,
    /// or JPEG instead of PNG) until they fit.
    public static let maxEncodedBytes = 1_000_000

    public enum Outcome: Sendable {
        case loaded(attachment: ImageAttachment, width: Int, height: Int)
        case notAnImage
        case fileTooLarge(bytes: Int)
        case decodeFailed
    }

    /// Classifies the leading bytes of `data` as an image and returns its
    /// MIME type, or nil when it is not an image.
    public static func mimeType(of data: Data) -> String? {
        let b = [UInt8](data.prefix(16))

        func has(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard offset + bytes.count <= b.count else { return false }
            for i in bytes.indices where b[offset + i] != bytes[i] { return false }
            return true
        }

        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if has([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if has([0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if has([0x42, 0x4D]) { return "image/bmp" }
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        if has([0x52, 0x49, 0x46, 0x46]), has([0x57, 0x45, 0x42, 0x50], at: 8) {
            return "image/webp"
        }
        // ISO BMFF (HEIC/HEIF): "ftyp" box at offset 4 with an HEIC brand.
        if has([0x66, 0x74, 0x79, 0x70], at: 4), let brand = String(bytes: b[8..<12], encoding: .ascii) {
            if ["heic", "heif", "hevc", "mif1", "msf1"].contains(brand) { return "image/heic" }
        }
        return nil
    }

    /// True when the head of the file looks binary (contains a NUL byte in
    /// the first 8KB). Used to reject non-image binaries instead of letting
    /// them through the text-reading path.
    public static func looksBinary(_ head: Data) -> Bool {
        head.prefix(8192).contains(0)
    }

    /// Reads and preprocesses the image file at `path`: decodes it with
    /// ImageIO, downsamples so the longest edge is at most `maxEdge`, and
    /// re-encodes it (PNG for PNG/GIF sources to keep transparency, JPEG
    /// otherwise) so the result stays around `maxEncodedBytes` or smaller.
    public static func load(atPath path: String) -> Outcome {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .decodeFailed
        }
        let sourceMIME = mimeType(of: data)
        guard sourceMIME != nil else { return .notAnImage }
        guard data.count <= maxFileBytes else { return .fileTooLarge(bytes: data.count) }

        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxEdge
                ] as CFDictionary
            )
        else {
            return .decodeFailed
        }

        // Try the preferred format first, then fall back to JPEG at
        // reduced quality, so photo-like images that bloat as PNG end up
        // under the size budget.
        let preferPNG = sourceMIME == "image/png" || sourceMIME == "image/gif"
        let candidates: [(UTType, [CFString: Any]?, String)] = preferPNG
            ? [
                (UTType.png, nil, "image/png"),
                (UTType.jpeg, jpegProperties(0.85), "image/jpeg"),
                (UTType.jpeg, jpegProperties(0.6), "image/jpeg")
            ]
            : [
                (UTType.jpeg, jpegProperties(0.85), "image/jpeg"),
                (UTType.jpeg, jpegProperties(0.6), "image/jpeg")
            ]
        var best: (mimeType: String, data: Data)?
        for (type, properties, mimeType) in candidates {
            guard let encoded = encodedData(for: image, type: type, properties: properties) else {
                continue
            }
            if encoded.count <= maxEncodedBytes {
                best = (mimeType, encoded)
                break
            }
            if best == nil || encoded.count < best!.data.count {
                best = (mimeType, encoded)
            }
        }
        guard let (mimeType, data) = best else { return .decodeFailed }

        return .loaded(
            attachment: ImageAttachment(
                mimeType: mimeType,
                base64: data.base64EncodedString(),
                source: path
            ),
            width: image.width,
            height: image.height
        )
    }

    private static func jpegProperties(_ quality: Double) -> [CFString: Any] {
        [kCGImageDestinationLossyCompressionQuality: quality]
    }

    private static func encodedData(
        for image: CGImage,
        type: UTType,
        properties: [CFString: Any]?
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, (properties ?? [:]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
