//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPClientToolsGrepTests.swift
//

import Foundation
import Testing

@testable import Tools

@Suite("ACPClientTools file tools (grep_file, list_directory, read_file)")
struct ACPClientToolsGrepTests {
    private final class Temp: @unchecked Sendable {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("terrapin-grep-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func write(_ path: String, _ contents: String) {
            let file = url.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func makeWorkspace() -> (tools: ACPClientTools, cwd: String, temp: Temp) {
        let temp = Temp()
        temp.write("Sources/Foo.swift", "hello world\nCanImport test\n")
        temp.write("Sources/sub/Bar.swift", "CANIMPORT\n")
        temp.write("notes.txt", "canimport in notes\n")
        temp.write(".git/ignore", "canimport in git (should be skipped)\n")
        temp.write("blob.bin", "\u{00}\u{01}canimport\u{00}\n")
        return (ACPClientTools(clientChannel: ClientChannel()), temp.url.path, temp)
    }

    private func grep(_ tools: ACPClientTools, _ cwd: String, _ args: String) async -> String {
        (await tools.execute(
            name: "grep_file",
            argsJSON: args,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
    }

    @Test func wholeTreeRegexCaseInsensitive() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = await grep(
            tools, cwd,
            #"{"query": "canimport", "caseSensitive": false, "isRegex": true}"#
        )
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines.contains { $0.hasSuffix("Foo.swift:2:CanImport test") })
        #expect(lines.contains { $0.hasSuffix("Bar.swift:1:CANIMPORT") })
        #expect(lines.contains { $0.hasSuffix("notes.txt:1:canimport in notes") })
        #expect(!result.contains(".git"))
        #expect(!result.contains("blob.bin"))
    }

    @Test func directoryGlobRestrictsToSources() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = await grep(
            tools, cwd,
            #"{"query": "canimport", "pathPattern": "Sources/**", "caseSensitive": false, "isRegex": true}"#
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("/Sources/") })
    }

    @Test func basenameGlobFiltersByExtension() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = await grep(
            tools, cwd,
            #"{"query": "canimport", "pathPattern": "*.swift", "caseSensitive": false, "isRegex": true}"#
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains(".swift:") })
    }

    @Test func literalCaseSensitive() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = await grep(
            tools, cwd,
            #"{"query": "CanImport", "caseSensitive": true, "isRegex": false}"#
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix("Foo.swift:2:CanImport test"))
    }

    @Test func noMatchesReturnsMessage() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = await grep(
            tools, cwd,
            #"{"query": "no-such-xyzzy", "caseSensitive": true, "isRegex": true}"#
        )
        #expect(result == "No matches found for 'no-such-xyzzy'.")
    }

    @Test func unmatchedDirectoryGlobReportsNoFiles() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = await grep(
            tools, cwd,
            #"{"query": "canimport", "pathPattern": "Nope/*", "caseSensitive": true, "isRegex": true}"#
        )
        #expect(result.contains("No files match path pattern 'Nope/*'"))
    }

    @Test func invalidRegexReportsFailure() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = await grep(
            tools, cwd,
            #"{"query": "([unclosed", "caseSensitive": true, "isRegex": true}"#
        )
        #expect(result.hasPrefix("Grep execution failed"))
    }

    @Test func listDirectoryShowsNamesAndSizes() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = (await tools.execute(
            name: "list_directory",
            argsJSON: "{}",
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
        #expect(result.contains("Sources/ (directory)"))
        #expect(result.contains("notes.txt ("))
        #expect(result.contains(" bytes)"))
        #expect(!result.contains(".git")) // dotfiles are hidden, like ls -l
        #expect(result.contains("blob.bin ("))
    }

    @Test func listDirectoryMissingPathIsError() async {
        let (tools, cwd, temp) = makeWorkspace()
        let result = (await tools.execute(
            name: "list_directory",
            argsJSON: #"{"path": "does-not-exist"}"#,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
        #expect(result.hasPrefix("Error listing directory"))
    }

    @Test func listEmptyDirectory() async {
        let (tools, cwd, temp) = makeWorkspace()
        try? FileManager.default.createDirectory(atPath: cwd + "/empty", withIntermediateDirectories: true)
        let result = (await tools.execute(
            name: "list_directory",
            argsJSON: #"{"path": "empty"}"#,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
        #expect(result == "(empty directory)")
    }

    @Test func readFileStripsCRLFLineEndings() async {
        let (tools, cwd, temp) = makeWorkspace()
        temp.write("crlf.txt", "first line\r\nsecond line\r\nthird line\r\n")
        let result = (await tools.execute(
            name: "read_file",
            argsJSON: #"{"path": "crlf.txt", "line": 2, "limit": 2}"#,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
        #expect(result == "second line\nthird line")
    }

    @Test func readFileResolvesWorkspaceNamePrefixAndAbsolutePaths() async {
        let (tools, cwd, temp) = makeWorkspace()
        let rootName = (cwd as NSString).lastPathComponent
        let prefixed = (await tools.execute(
            name: "read_file",
            argsJSON: #"{"path": "\#(rootName)/notes.txt"}"#,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
        #expect(prefixed == "canimport in notes\n")
        
        let absolute = (await tools.execute(
            name: "read_file",
            argsJSON: #"{"path": "\#(cwd)/notes.txt"}"#,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
        #expect(absolute == "canimport in notes\n")
    }

    @Test func moveFileRefusesDestinationOutsideWorkspace() async {
        let (tools, cwd, temp) = makeWorkspace()
        let outside = temp.url.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        let result = (await tools.execute(
            name: "move_file",
            argsJSON: #"{"path": "notes.txt", "newPath": "\#(outside.path)"}"#,
            cwd: cwd,
            sessionId: "test",
            sendJSON: { _ in }
        )).text
        #expect(result.contains("path is outside the workspace"))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: cwd + "/notes.txt"))
    }
}
