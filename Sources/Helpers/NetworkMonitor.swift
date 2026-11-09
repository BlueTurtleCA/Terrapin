//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// NetworkMonitor.swift
//

import Foundation
#if canImport(Network)
import Network
#endif

/// Tracks the machine's network connectivity using ``NWPathMonitor`` so
/// internet-dependent tools can fail fast with a clear message instead of
/// waiting for a request timeout.
///
/// Detection is interface-level (e.g. Wi-Fi shut off), not an internet
/// reachability probe: a satisfied path is treated as online.
///
/// On platforms without the Network framework (e.g. Windows) monitoring is
/// unavailable, so the monitor fails open and always reports online.
public actor NetworkMonitor {
    public static let shared = NetworkMonitor()

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.terrapin.network-monitor")
    #endif
    // Fail open: assume online until the first path update says otherwise,
    // so tools are never blocked before monitoring has produced a result.
    private var online = true
    private var started = false

    public init() {}

    /// Starts path monitoring. Safe to call multiple times.
    public func start() {
        guard !started else { return }
        started = true
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.update(online: path.status == .satisfied) }
        }
        monitor.start(queue: queue)
        #endif
    }

    /// Whether the machine currently has a network path (Wi-Fi, Ethernet,
    /// cellular, ...). Fails open (true) until the first path update arrives.
    public var isOnline: Bool { online }

    private func update(online newValue: Bool) {
        online = newValue
    }

    /// Returns a note to inject into the conversation when the network state
    /// changed since the previous turn, or nil when there is nothing to
    /// report. `previous` is nil on the first turn for a session.
    public static func transitionNote(online: Bool, previous: Bool?) -> String? {
        switch (previous, online) {
        case (nil, false), (true, false):
            return """
            System Note: The machine is currently offline. web_search and web_fetch will fail until the connection is restored. Do not attempt web tools; rely on local files and your existing knowledge, and let the user know the network is down.
            """
        case (false, true):
            return "System Note: The network connection has been restored. web_search and web_fetch are available again."
        default:
            return nil
        }
    }
}
