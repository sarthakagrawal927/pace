//
//  PaceWatchModeCommandParserTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Pace

struct PaceWatchModeCommandParserTests {
    @Test func startCommands() async throws {
        for transcript in [
            "please watch my screen for a while",
            "start watch mode",
            "turn on watch mode",
            "monitor my screen",
            "watch for changes while I work",
        ] {
            #expect(PaceWatchModeCommandParser.parse(transcript) == .start)
        }
    }

    @Test func stopCommands() async throws {
        for transcript in [
            "stop watching now",
            "turn off watch mode",
            "disable watch mode",
            "do not watch my screen anymore",
            "don't watch my screen",
        ] {
            #expect(PaceWatchModeCommandParser.parse(transcript) == .stop)
        }
    }

    @Test func stopWinsWhenTranscriptContainsBothDirections() async throws {
        let command = PaceWatchModeCommandParser.parse("stop watching and do not watch my screen")
        #expect(command == .stop)
    }

    @Test func unrelatedTranscriptDoesNotTriggerWatchMode() async throws {
        #expect(PaceWatchModeCommandParser.parse("what is on my screen") == nil)
        #expect(PaceWatchModeCommandParser.parse("open safari") == nil)
        #expect(PaceWatchModeCommandParser.parse("") == nil)
    }
}
