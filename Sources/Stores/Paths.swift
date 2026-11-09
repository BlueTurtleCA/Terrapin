//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Paths.swift
//

import Foundation

/// Centralized on-disk locations for Terrapin.
///
/// User-level state lives under `~/.terrapin/`; workspace-level scratch
/// lives under `./.terrapin/` in the session's working directory.
public enum TerrapinPaths {
    /// User-level root: `~/.terrapin`.
    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".terrapin", isDirectory: true)
    }

    /// Persisted session state: `~/.terrapin/sessions`.
    public static var sessionsDirectory: URL {
        userDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// LLM request debug logs: `~/.terrapin/logs`.
    public static var logsDirectory: URL {
        userDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// Workspace-level scratch directory name (web fetch cache, ...).
    public static let workspaceDirectoryName = ".terrapin"

    /// Workspace-level web fetch cache: `./.terrapin/web` under `cwd`.
    public static func webCacheDirectory(in cwd: String) -> String {
        (cwd as NSString).appendingPathComponent(
            workspaceDirectoryName + "/web"
        )
    }
}
