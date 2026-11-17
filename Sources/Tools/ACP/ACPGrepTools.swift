//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPGrepTools.swift
//

import Foundation

/// The grep_file tool: pattern matching, workspace file walking
/// and shell-style glob support.
extension ACPClientTools {
    func grepTextFile(argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        let callId = "call_" + UUID().uuidString
        
        guard let args = Self.parseArgs(argsJSON) else {
            return "Error: Invalid JSON parameters supplied to grep_file"
        }
        guard let query = args["query"] as? String, !query.isEmpty
                else {
            return "Error: Missing or empty 'query' parameter"
        }
        
        let pathPattern = args["pathPattern"] as? String
        let caseSensitive = args["caseSensitive"] as? Bool ?? false
        let isRegex = args["isRegex"] as? Bool ?? true
        
            
        let (matches, _, commandString) = await runStandardGrep(
            query: query,
            cwd: cwd,
            pathPattern: pathPattern,
            caseSensitive: caseSensitive,
            isRegex: isRegex
        )
        
        let resultText = matches.isEmpty ? "No matches found for '\(query)'." : matches.joined(separator: "\n")
        
        Self.sendToolCall(
            sessionId: sessionId,
            callId: callId,
            name: "grep_file",
            title: commandString,
            status: "in_progress",
            sendJSON: sendJSON
        )
        
        
        Self.sendToolCallUpdate(
            sessionId: sessionId,
            callId: callId,
            status: "completed",
            title: commandString,
            sendJSON: sendJSON
        )
            
        return resultText
    }

    private func runStandardGrep(
        query: String,
        cwd: String,
        pathPattern: String?,
        caseSensitive: Bool,
        isRegex: Bool
    ) async -> (matches: [String], locations: [[String: Any]], cmd: String) {
        // grep --include only matches file basenames, so a pattern with a
        // directory component (e.g. "Sources/*") can never match. Enumerate
        // the workspace instead and search the files whose relative path
        // matches the glob. Both separator styles count as directory
        // components ("Sources\*" on Windows).
        let searchTargets: [String]
        if let pattern = pathPattern, !pattern.isEmpty,
           pattern.contains("/") || pattern.contains("\\") {
            searchTargets = Self.filesMatchingGlob(pattern, under: cwd)
            if searchTargets.isEmpty {
                return (
                    ["No files match path pattern '\(pattern)'."],
                    [],
                    "grep (no files match '\(pattern)')"
                )
            }
        } else if let pattern = pathPattern, !pattern.isEmpty {
            // A basename-only pattern filters by file name (grep --include).
            searchTargets = Self.walkFiles(under: cwd)
                .filter { Self.globMatches(pattern, path: ($0.absolute as NSString).lastPathComponent) }
                .map(\.absolute)
        } else {
            searchTargets = Self.walkFiles(under: cwd).map(\.absolute)
        }
        
        // Extended regex by default so `|`, `+`, `?`, ... behave as most
        // models expect; literal matching otherwise (grep -F).
        let regex: NSRegularExpression?
        if isRegex {
            guard let compiled = try? NSRegularExpression(
                pattern: query,
                options: caseSensitive ? [] : [.caseInsensitive]
            ) else {
                return (
                    ["Grep execution failed: invalid regex '\(query)'."],
                    [],
                    "grep -E -e \(query)"
                )
            }
            regex = compiled
        } else {
            regex = nil
        }
        
        // A long explicit file list makes for an unreadable title, so show
        // the glob instead when the search was narrowed to matched files.
        let flags = "\(isRegex ? "-E" : "-F")\(caseSensitive ? "" : " -i")"
        let commandString: String
        if searchTargets.count > 1, let pattern = pathPattern {
            commandString = "grep \(flags) -e \(query) [\(searchTargets.count) files matching '\(pattern)']"
        } else {
            commandString = "grep \(flags) -e \(query) \(cwd)"
        }
        
        var matches: [String] = []
        var locations: [[String: Any]] = []
        
        searchTargetsLoop: for file in searchTargets {
            // Skip files that are not valid UTF-8 or contain NUL bytes
            // (grep -I).
            guard let content = try? String(contentsOfFile: file, encoding: .utf8),
                  !content.contains("\0")
            else { continue }
            
            for (index, line) in content.components(separatedBy: .newlines).enumerated() {
                let matched: Bool
                if let regex {
                    matched = regex.firstMatch(
                        in: line,
                        range: NSRange(line.startIndex..., in: line)
                    ) != nil
                } else {
                    matched = caseSensitive
                        ? line.contains(query)
                        : line.lowercased().contains(query.lowercased())
                }
                guard matched else { continue }
                
                let lineNumber = index + 1
                matches.append("\(file):\(lineNumber):\(line)")
                locations.append([
                    "path": file,
                    "line": lineNumber,
                    "column": 1
                ])
                
                // Report at most 100 matches, like the grep -r output cap.
                if matches.count >= 100 { break searchTargetsLoop }
            }
        }
        
        return (matches, locations, commandString)
    }
    
    /// Enumerates the regular files under `directory` (skipping .git, .build
    /// and DerivedData). Returns each file's absolute path plus its path
    /// relative to `directory` with forward slashes, so glob matching works
    /// the same on every platform.
    private static func walkFiles(under directory: String) -> [(absolute: String, relative: String)] {
        let fileManager = FileManager.default
        // Resolve symlinks (e.g. /var -> /private/var on macOS) so the
        // enumerated paths share the root's prefix.
        let rootURL = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        let excludedDirectories: Set<String> = [".git", ".build", "DerivedData"]
        
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            return []
        }
        
        let rootPath = rootURL.path.replacingOccurrences(of: "\\", with: "/")
        var files: [(absolute: String, relative: String)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true {
                let fileURL = url.standardizedFileURL
                let normalizedPath = fileURL.path.replacingOccurrences(of: "\\", with: "/")
                guard normalizedPath.hasPrefix(rootPath + "/") else { continue }
                files.append((fileURL.path, String(normalizedPath.dropFirst(rootPath.count + 1))))
            } else if values?.isDirectory == true, excludedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
            }
        }
        return files
    }
    
    /// Enumerates the regular files under `directory` (skipping .git, .build
    /// and DerivedData) whose path relative to `directory` matches the glob
    /// `pattern`.
    private static func filesMatchingGlob(_ pattern: String, under directory: String) -> [String] {
        walkFiles(under: directory).compactMap { file in
            globMatches(pattern, path: file.relative) ? file.absolute : nil
        }
    }
    
    /// Matches `path` against a shell-style glob: `*` matches any run of
    /// characters except a path separator, `**` matches anything including
    /// separators, `?` matches a single character except a separator, and
    /// every other character is literal.
    private static func globMatches(_ pattern: String, path: String) -> Bool {
        guard let regex = globRegex(for: pattern) else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
    
    /// Regex classes for `*` (any run) and `?` (single character): anything
    /// except a path separator. Windows treats both "/" and "\" as
    /// separators; POSIX only "/".
    #if os(Windows)
    private static let globSingleSegment = "[^/\\\\]*"
    private static let globSingleChar = "[^/\\\\]"
    #else
    private static let globSingleSegment = "[^/]*"
    private static let globSingleChar = "[^/]"
    #endif
    
    private static func globRegex(for pattern: String) -> NSRegularExpression? {
        // The paths being matched are slash-normalized, so backslash
        // separators in the pattern mean the same as forward slashes.
        let normalizedPattern = Self.normalizedSeparators(pattern)
        var source = "^"
        var index = normalizedPattern.startIndex
        while index < normalizedPattern.endIndex {
            let character = normalizedPattern[index]
            switch character {
            case "*":
                let next = normalizedPattern.index(after: index)
                if next < normalizedPattern.endIndex, normalizedPattern[next] == "*" {
                    source += ".*"
                    index = normalizedPattern.index(after: next)
                } else {
                    source += Self.globSingleSegment
                    index = next
                }
            case "?":
                source += Self.globSingleChar
                index = normalizedPattern.index(after: index)
            default:
                source += NSRegularExpression.escapedPattern(for: String(character))
                index = normalizedPattern.index(after: index)
            }
        }
        source += "$"
        return try? NSRegularExpression(pattern: source)
    }
}
