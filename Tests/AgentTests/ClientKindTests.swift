//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ClientKindTests.swift
//

import Foundation
import Testing
import Stores

@Suite("ClientKind detection")
struct ClientKindTests {
    @Test("clientInfo naming Android Studio selects the androidstudio client")
    func androidStudioName() {
        let kind = ClientKind.detect(
            clientInfo: ["name": "Android Studio", "title": "Android Studio"],
            environment: [:]
        )
        #expect(kind == .androidstudio)
    }

    @Test("clientInfo with android in the title selects the androidstudio client")
    func androidStudioTitle() {
        let kind = ClientKind.detect(
            clientInfo: ["name": "Studio", "title": "Android Studio"],
            environment: [:]
        )
        #expect(kind == .androidstudio)
    }

    @Test("xcode detection takes precedence over android")
    func xcodePrecedence() {
        let kind = ClientKind.detect(
            clientInfo: ["name": "Xcode", "title": "Xcode"],
            environment: [:]
        )
        #expect(kind == .xcode)
    }

    @Test("unrecognized names stay generic")
    func genericName() {
        let kind = ClientKind.detect(
            clientInfo: ["name": "Zed"],
            environment: [:]
        )
        #expect(kind == .generic(name: "Zed"))
    }

    @Test("an unidentified client uses the configured fallback")
    func fallback() {
        let kind = ClientKind.detect(
            clientInfo: nil,
            environment: [:],
            fallback: .androidstudio
        )
        #expect(kind == .androidstudio)
    }
}
