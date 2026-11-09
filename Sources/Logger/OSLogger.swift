//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// OSLogger.swift
//

#if canImport(os)
import os

public struct OSLogger: Loggable, Sendable {
    let sharedLogger = os.Logger(subsystem: "ca.blueturtle.terrapin", category: "ACP")
    
    public init() {}
    
    public func debug(_ message: String) {
        sharedLogger.notice("\(message, privacy: .public)")
    }
}
#else
// Platforms without os.log (e.g. Windows) fall back to console logging.
public struct OSLogger: Loggable, Sendable {
    private let console = ConsoleLogger()
    
    public init() {}
    
    public func debug(_ message: String) {
        console.debug(message)
    }
}
#endif
