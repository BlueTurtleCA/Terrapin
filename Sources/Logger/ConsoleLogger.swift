//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ConsoleLogger.swift
//

import Foundation

public struct ConsoleLogger: Loggable, Sendable {
    public init() {}
    
    public func debug(_ message: String) {
        FileHandle.standardError.write(Data("[DEBUG] \(message)\n".utf8))
    }
}
