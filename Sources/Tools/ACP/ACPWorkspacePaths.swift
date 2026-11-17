//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPWorkspacePaths.swift
//

import Foundation

/// Argument parsing and workspace path resolution shared by the ACP
/// client tools.
extension ACPClientTools {
    static func parseArgs(_ argsJSON: String) -> [String: Any]? {
        guard let data = argsJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Replaces backslash separators with forward slashes. On Windows both
    /// characters are path separators (and "\" is never a file-name
    /// character), so the rewrite is always safe; on POSIX "\" is a legal
    /// file-name character and is left alone.
    static func normalizedSeparators(_ path: String) -> String {
        #if os(Windows)
        return path.replacingOccurrences(of: "\\", with: "/")
        #else
        return path
        #endif
    }
    
    /// True when the path is absolute on the current platform: POSIX paths
    /// start with "/", Windows paths with a drive letter ("C:\", "C:/") or
    /// a UNC prefix ("\\server\share").
    private static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        #if os(Windows)
        let characters = Array(path)
        if characters.count >= 3,
           characters[0].isLetter,
           characters[1] == ":",
           characters[2] == "/" || characters[2] == "\\" {
            return true
        }
        if path.hasPrefix("\\\\") { return true }
        #endif
        return false
    }
    
    static func resolveWorkspacePath(relativePath: String, workspaceRoot: String) -> String {
        let expandedRaw = (relativePath as NSString).expandingTildeInPath
        let expandedRoot = (workspaceRoot as NSString).expandingTildeInPath
        
        let rootURL = URL(fileURLWithPath: expandedRoot).standardizedFileURL
            
        // 1. Absolute paths (POSIX "/..." or Windows "C:\..." / UNC)
        if Self.isAbsolutePath(expandedRaw) {
            return URL(fileURLWithPath: expandedRaw).standardizedFileURL.path
        }
            
        // Normalize separators so the prefix check below works on every
        // platform (the model may write Windows paths with backslashes).
        let normalized = Self.normalizedSeparators(expandedRaw)
            
        // 2. Strip redundant workspace name prefix EVEN IF the file doesn't exist yet
        let rootName = rootURL.lastPathComponent // "Terrapin"
        var cleanRelative = normalized
        if normalized.hasPrefix("\(rootName)/") {
            cleanRelative = String(normalized.dropFirst(rootName.count + 1)) // "SUMMARY.md"
        }
            
        // 3. Resolve clean path against workspace root
        let resolvedURL = rootURL.appendingPathComponent(cleanRelative).standardizedFileURL
        return resolvedURL.path
    }
    
    static func isWithinWorkspace(_ path: String, workspaceRoot: String) -> Bool {
        let root = Self.normalizedSeparators(
            URL(fileURLWithPath: (workspaceRoot as NSString).expandingTildeInPath).standardizedFileURL.path
        )
        let standardized = Self.normalizedSeparators(URL(fileURLWithPath: path).standardizedFileURL.path)
        return standardized == root || standardized.hasPrefix(root + "/")
    }
    
    /// The inverse of resolveWorkspacePath: a workspace-relative path in the
    /// form the Xcode MCP bridge expects (e.g. "Terrapin/Sources/Foo.swift").
    static func workspaceRelativePath(_ absolutePath: String, workspaceRoot: String) -> String {
        let root = URL(fileURLWithPath: (workspaceRoot as NSString).expandingTildeInPath).standardizedFileURL
        let abs = URL(fileURLWithPath: absolutePath).standardizedFileURL
        let rootPath = Self.normalizedSeparators(root.path)
        let absPath = Self.normalizedSeparators(abs.path)
        guard absPath.hasPrefix(rootPath + "/") else {
            return absolutePath
        }
        let relative = String(absPath.dropFirst(rootPath.count + 1))
        return root.lastPathComponent + "/" + relative
    }
    
    static func makeArgsJSON(_ args: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
