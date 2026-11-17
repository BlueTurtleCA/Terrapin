//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPClientToolsImageTests.swift
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Stores

@testable import Tools

@Suite("ACPClientTools read_file image support")
struct ACPClientToolsImageTests {
    private final class Temp: @unchecked Sendable {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("terrapin-image-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        @discardableResult
        func write(_ path: String, _ data: Data) -> String {
            let file = url.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
            return file.path
        }
    }

    private func makeTools(_ temp: Temp) -> ACPClientTools {
        ACPClientTools(clientChannel: ClientChannel())
    }

    private func read(_ tools: ACPClientTools, _ cwd: String, _ path: String) async -> ToolResult {
        await tools.execute(
            name: "read_file",
            argsJSON: #"{"path": "\#(path)"}"#,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )
    }

    /// Renders a gradient (or noise, so encoders cannot compress it to
    /// nothing) into an actual PNG or JPEG on disk.
    private func writeImage(
        _ temp: Temp,
        name: String,
        width: Int,
        height: Int,
        type: UTType,
        noise: Bool = false
    ) -> String {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if noise {
            for y in stride(from: 0, to: height, by: 8) {
                for x in stride(from: 0, to: width, by: 8) {
                    context.setFillColor(
                        red: .random(in: 0...1),
                        green: .random(in: 0...1),
                        blue: .random(in: 0...1),
                        alpha: 1
                    )
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        } else {
            let colors = [
                CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                CGColor(red: 0, green: 0, blue: 1, alpha: 1)
            ] as CFArray
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: CGFloat(height)),
                options: []
            )
        }
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("failed to encode test image")
        }
        return temp.write(name, data as Data)
    }

    private func decodedDimensions(of attachment: ImageAttachment) -> (Int, Int)? {
        guard let data = Data(base64Encoded: attachment.base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    @Test func pngReturnsImageAttachment() async {
        let temp = Temp()
        let tools = makeTools(temp)
        let path = writeImage(temp, name: "gradient.png", width: 3000, height: 2000, type: .png)

        let result = await read(tools, temp.url.path, path)

        #expect(result.image != nil)
        #expect(["image/png", "image/jpeg"].contains(result.image?.mimeType ?? ""))
        #expect(result.image?.source == path)
        #expect(result.text.hasPrefix("Image of '\(path)'"))
        #expect(result.text.contains("3000x2000") == false) // reported size is the downscaled one
    }

    @Test func jpegStaysJPEG() async {
        let temp = Temp()
        let tools = makeTools(temp)
        let path = writeImage(temp, name: "photo.jpg", width: 1600, height: 1200, type: .jpeg)

        let result = await read(tools, temp.url.path, path)

        #expect(result.image?.mimeType == "image/jpeg")
        #expect((result.image?.base64.count ?? 0) > 0)
    }

    @Test func largeImageIsDownscaledToMaxEdge() async {
        let temp = Temp()
        let tools = makeTools(temp)
        // 3000x2000 gradient: long enough to exercise the thumbnail path.
        let path = writeImage(temp, name: "big.png", width: 3000, height: 2000, type: .png)

        let result = await read(tools, temp.url.path, path)

        guard let attachment = result.image, let (width, height) = decodedDimensions(of: attachment) else {
            Issue.record("no image attachment or undecodable payload")
            return
        }
        #expect(max(width, height) <= ImageSupport.maxEdge)
        #expect(width >= ImageSupport.maxEdge || height < ImageSupport.maxEdge) // scaled, not padded
    }

    @Test func noisyPNGFallsBackToJPEG() async {
        let temp = Temp()
        let tools = makeTools(temp)
        // 8px random blocks: incompressible, so the PNG re-encode blows past
        // the size budget and the JPEG fallback is used instead.
        let path = writeImage(temp, name: "noise.png", width: 1600, height: 1200, type: .png, noise: true)

        let result = await read(tools, temp.url.path, path)

        #expect(result.image?.mimeType == "image/jpeg")
        if let attachment = result.image, let (width, height) = decodedDimensions(of: attachment) {
            #expect(max(width, height) <= ImageSupport.maxEdge)
        }
    }

    @Test func binaryNonImageFileIsRejected() async {
        let temp = Temp()
        let tools = makeTools(temp)
        let path = temp.write("blob.bin", Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x41, 0x42]))

        let result = await read(tools, temp.url.path, path)

        #expect(result.image == nil)
        #expect(result.text.hasPrefix("Error"))
        #expect(result.text.contains("binary file"))
    }

    @Test func oversizedImageFileIsRejected() async {
        let temp = Temp()
        let tools = makeTools(temp)
        // Valid PNG magic followed by enough zero bytes to exceed the cap;
        // load() must report fileTooLarge before it ever decodes.
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(count: ImageSupport.maxFileBytes + 1024))
        let path = temp.write("huge.png", data)

        let result = await read(tools, temp.url.path, path)

        #expect(result.image == nil)
        #expect(result.text.hasPrefix("Error"))
        #expect(result.text.contains("too large"))
    }

    @Test func imageReadIsRefusedWhenVisionIsDisabled() async {
        let temp = Temp()
        let tools = ACPClientTools(clientChannel: ClientChannel(), supportsVision: false)
        let path = writeImage(temp, name: "gradient.png", width: 400, height: 300, type: .png)

        let result = await read(tools, temp.url.path, path)

        #expect(result.image == nil)
        #expect(result.text.hasPrefix("Error"))
        #expect(result.text.contains("does not support vision"))
    }

    @Test func imageReadSendsImageContentToClient() async {
        let temp = Temp()
        let tools = makeTools(temp)
        let path = writeImage(temp, name: "gradient.png", width: 400, height: 300, type: .png)

        let lock = NSLock()
        var sent: [[String: Any]] = []
        let result = await tools.execute(
            name: "read_file",
            argsJSON: #"{"path": "\#(path)"}"#,
            cwd: temp.url.path,
            sessionId: "test",
            sendJSON: { json in
                lock.lock()
                sent.append(json)
                lock.unlock()
            }
        )

        #expect(result.image != nil)

        // The completed tool_call_update must carry the picture as ACP
        // content so the client can show it, not just the status change.
        let updates: [[String: Any]] = sent.compactMap { json in
            (json["params"] as? [String: Any])?["update"] as? [String: Any]
        }
        let completion = updates.first { ($0["status"] as? String) == "completed" }
        guard let content = completion?["content"] as? [[String: Any]] else {
            Issue.record("completed update has no content")
            return
        }
        #expect(content.contains {
            ($0["type"] as? String) == "content"
                && (($0["content"] as? [String: Any])?["type"] as? String) == "text"
        })
        let imageBlock = content.compactMap { item -> [String: Any]? in
            guard (item["type"] as? String) == "content" else { return nil }
            let block = item["content"] as? [String: Any]
            return (block?["type"] as? String) == "image" ? block : nil
        }.first
        #expect(imageBlock != nil)
        #expect(["image/png", "image/jpeg"].contains(imageBlock?["mimeType"] as? String ?? ""))
        guard let base64 = imageBlock?["data"] as? String, !base64.isEmpty,
              let decoded = Data(base64Encoded: base64), !decoded.isEmpty
        else {
            Issue.record("image content block has no decodable base64 data")
            return
        }
        // The client must receive the exact payload the model is given.
        #expect(base64 == result.image?.base64)
    }

    @Test func readFileDefinitionTracksVisionSupport() async {
        let disabled = ACPClientTools(clientChannel: ClientChannel(), supportsVision: false)
        let enabled = ACPClientTools(clientChannel: ClientChannel())
        let reported = ACPClientTools(clientChannel: ClientChannel(), supportsVision: true)

        let disabledRead = (await disabled.definitions()).first { $0.function.name == "read_file" }!
        let enabledRead = (await enabled.definitions()).first { $0.function.name == "read_file" }!
        let reportedRead = (await reported.definitions()).first { $0.function.name == "read_file" }!

        #expect(disabledRead.function.description.contains("cannot view image files"))
        #expect(disabledRead.function.description.contains("you can see") == false)
        #expect(enabledRead.function.description.contains("images you can see"))
        #expect(reportedRead.function.description.contains("images you can see"))
    }

    @Test func mimeTypeSniffing() {
        func magic(_ bytes: [UInt8]) -> Data { Data(bytes) }
        #expect(ImageSupport.mimeType(of: magic([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
        #expect(ImageSupport.mimeType(of: magic([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(ImageSupport.mimeType(of: magic([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) == "image/gif")
        #expect(ImageSupport.mimeType(of: magic([0x42, 0x4D, 0x00, 0x00])) == "image/bmp")
        #expect(ImageSupport.mimeType(of: magic([0x49, 0x49, 0x2A, 0x00])) == "image/tiff")
        #expect(ImageSupport.mimeType(of: magic([0x4D, 0x4D, 0x00, 0x2A])) == "image/tiff")
        #expect(
            ImageSupport.mimeType(of: magic([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]))
                == "image/webp"
        )
        #expect(
            ImageSupport.mimeType(of: magic(Array("....ftypheic".utf8))) == "image/heic"
        )
        #expect(ImageSupport.mimeType(of: magic([0x50, 0x4B, 0x03, 0x04])) == nil) // zip
        #expect(ImageSupport.mimeType(of: magic(Array("func Foo() {}".utf8))) == nil) // source
    }

    @Test func binaryDetection() {
        #expect(ImageSupport.looksBinary(Data([0x61, 0x00, 0x62])))
        #expect(ImageSupport.looksBinary(Data()) == false)
        #expect(ImageSupport.looksBinary(Data("plain text, no NUL".utf8)) == false)
    }
}
