//
//  PaceDeepLinkParserTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceDeepLinkParserTests {
    @Test func listenURLParsesToStartListening() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://listen")!) == .startListening)
    }

    @Test func panelURLParsesToShowPanel() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://panel")!) == .showPanel)
    }

    @Test func chatURLDecodesPercentEncodedText() async throws {
        let command = PaceDeepLinkParser.parse(URL(string: "pace://chat?text=open%20notes")!)
        #expect(command == .sendChatMessage(text: "open notes"))
    }

    @Test func chatURLWithMissingOrEmptyTextReturnsNil() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://chat")!) == nil)
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://chat?text=%20%20")!) == nil)
    }

    @Test func chatURLOverCharacterCapReturnsNil() async throws {
        let atCapText = String(repeating: "a", count: PaceDeepLinkParser.maximumChatTextCharacterCount)
        let overCapText = atCapText + "a"
        #expect(
            PaceDeepLinkParser.parse(URL(string: "pace://chat?text=\(atCapText)")!)
                == .sendChatMessage(text: atCapText)
        )
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://chat?text=\(overCapText)")!) == nil)
    }

    @Test func watchURLParsesTrueAndFalse() async throws {
        #expect(
            PaceDeepLinkParser.parse(URL(string: "pace://watch?enabled=true")!)
                == .setWatchMode(enabled: true)
        )
        #expect(
            PaceDeepLinkParser.parse(URL(string: "pace://watch?enabled=false")!)
                == .setWatchMode(enabled: false)
        )
    }

    @Test func watchURLWithInvalidEnabledValueReturnsNil() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://watch?enabled=yes")!) == nil)
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://watch")!) == nil)
    }

    @Test func unknownHostReturnsNil() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://quit")!) == nil)
    }

    @Test func wrongSchemeReturnsNil() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "https://listen")!) == nil)
    }

    @Test func uppercaseSchemeAndHostParse() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "PACE://LISTEN")!) == .startListening)
    }

    @Test func extraPathSegmentsReturnNil() async throws {
        #expect(PaceDeepLinkParser.parse(URL(string: "pace://listen/now")!) == nil)
    }
}
