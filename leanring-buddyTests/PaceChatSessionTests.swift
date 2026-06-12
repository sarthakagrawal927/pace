//
//  PaceChatSessionTests.swift
//  leanring-buddyTests
//
//  Covers the chat-session backing store that powers the in-window
//  Conversations tab. Persistence still lives in the existing
//  `paceHistory` retrieval index — this suite exercises load/submit/
//  filter behaviours against a fake history source and a fake submitter
//  so we don't need a live `CompanionManager`.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceChatSessionTests {

    // MARK: - Test doubles

    final class FakeHistorySource: PaceChatHistorySource {
        var stubbedTurns: [PaceChatHistoryTurn] = []
        var loadCallCount: Int = 0

        func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] {
            loadCallCount += 1
            return stubbedTurns
        }
    }

    final class FakeTranscriptSubmitter: PaceChatTranscriptSubmitting {
        var submittedTranscripts: [String] = []

        func submitChatTranscript(_ transcript: String) {
            submittedTranscripts.append(transcript)
        }
    }

    private func makeSession(
        historySource: FakeHistorySource,
        submitter: FakeTranscriptSubmitter
    ) -> PaceChatSession {
        return PaceChatSession(
            historySource: historySource,
            transcriptSubmitter: submitter
        )
    }

    // MARK: - loadHistory roundtrip

    @Test func loadHistorySeedsTranscriptInOldestFirstOrder() async throws {
        let historySource = FakeHistorySource()
        let earlierDate = Date(timeIntervalSince1970: 1_000_000)
        let laterDate = Date(timeIntervalSince1970: 1_000_500)
        historySource.stubbedTurns = [
            PaceChatHistoryTurn(
                id: "turn-1",
                userText: "what's the time",
                paceText: "it's 9 pm",
                recordedAt: earlierDate
            ),
            PaceChatHistoryTurn(
                id: "turn-2",
                userText: "thanks",
                paceText: "you're welcome",
                recordedAt: laterDate
            ),
        ]
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(historySource: historySource, submitter: submitter)

        session.loadHistory()

        #expect(historySource.loadCallCount == 1)
        #expect(session.hasLoadedHistory == true)
        // Each turn expands into TWO messages (user + pace).
        #expect(session.messages.count == 4)
        #expect(session.messages.map(\.role) == [.user, .pace, .user, .pace])
        #expect(session.messages.map(\.body) == [
            "what's the time",
            "it's 9 pm",
            "thanks",
            "you're welcome",
        ])
    }

    @Test func loadHistoryDropsEmptyHalves() async throws {
        let historySource = FakeHistorySource()
        historySource.stubbedTurns = [
            PaceChatHistoryTurn(
                id: "session-end-marker",
                userText: "session ended (cause: idleTimeout)",
                paceText: "",
                recordedAt: Date()
            ),
        ]
        let session = makeSession(
            historySource: historySource,
            submitter: FakeTranscriptSubmitter()
        )

        session.loadHistory()

        #expect(session.messages.count == 1)
        #expect(session.messages.first?.role == .user)
    }

    @Test func loadHistoryIsIdempotentReplacingPriorTranscript() async throws {
        let historySource = FakeHistorySource()
        historySource.stubbedTurns = [
            PaceChatHistoryTurn(
                id: "turn-1",
                userText: "hi",
                paceText: "hello",
                recordedAt: Date()
            ),
        ]
        let session = makeSession(
            historySource: historySource,
            submitter: FakeTranscriptSubmitter()
        )

        session.loadHistory()
        let firstLoadCount = session.messages.count
        // Re-loading replaces the transcript wholesale so newly-arrived
        // voice turns show up when the window is re-opened.
        historySource.stubbedTurns.append(
            PaceChatHistoryTurn(
                id: "turn-2",
                userText: "another",
                paceText: "reply",
                recordedAt: Date()
            )
        )
        session.loadHistory()

        #expect(firstLoadCount == 2)
        #expect(session.messages.count == 4)
    }

    // MARK: - submitUserMessage

    @Test func submitUserMessageAppendsOptimisticRowAndForwardsToSubmitter() async throws {
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: submitter
        )

        session.submitUserMessage("  what's the time  ")

        #expect(submitter.submittedTranscripts == ["what's the time"])
        #expect(session.messages.count == 1)
        #expect(session.messages.first?.role == .user)
        #expect(session.messages.first?.body == "what's the time")
    }

    @Test func submitUserMessageDropsBlankInputs() async throws {
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: submitter
        )

        session.submitUserMessage("   ")
        session.submitUserMessage("")

        #expect(submitter.submittedTranscripts.isEmpty)
        #expect(session.messages.isEmpty)
    }

    // MARK: - appendCompletedTurn dedupes the optimistic row

    @Test func appendCompletedTurnDoesNotDuplicateOptimisticUserRow() async throws {
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: submitter
        )

        session.submitUserMessage("what's the time")
        session.appendCompletedTurn(
            userTranscript: "what's the time",
            assistantResponse: "it's 9 pm"
        )

        #expect(session.messages.count == 2)
        #expect(session.messages.first?.role == .user)
        #expect(session.messages.first?.body == "what's the time")
        #expect(session.messages.last?.role == .pace)
        #expect(session.messages.last?.body == "it's 9 pm")
    }

    @Test func appendCompletedTurnAppendsBothRowsWhenComingFromVoice() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        // Voice turn — submitUserMessage was never called, so both rows
        // should be appended fresh.
        session.appendCompletedTurn(
            userTranscript: "hello",
            assistantResponse: "hi there"
        )

        #expect(session.messages.map(\.role) == [.user, .pace])
        #expect(session.messages.map(\.body) == ["hello", "hi there"])
    }

    // MARK: - Mute toggle

    @Test func muteFlagStartsFalseAndPersistsForSessionInstance() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )

        #expect(session.isChatTTSMuted == false)
        session.isChatTTSMuted = true
        #expect(session.isChatTTSMuted == true)
        // Toggling is independent of history loading or message submission.
        session.submitUserMessage("anything")
        #expect(session.isChatTTSMuted == true)
        session.loadHistory()
        #expect(session.isChatTTSMuted == true)
    }

    // MARK: - Filtering

    @Test func filteredMessagesReturnsAllWhenQueryIsBlank() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.appendCompletedTurn(userTranscript: "hello", assistantResponse: "hi")
        session.appendCompletedTurn(userTranscript: "what time", assistantResponse: "9 pm")

        #expect(session.filteredMessages(matching: "").count == 4)
        #expect(session.filteredMessages(matching: "   ").count == 4)
    }

    @Test func filteredMessagesIsCaseInsensitiveSubstringMatch() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.appendCompletedTurn(userTranscript: "what's the launch date", assistantResponse: "Friday")
        session.appendCompletedTurn(userTranscript: "dinner ideas?", assistantResponse: "pasta or pizza")

        let launchMatches = session.filteredMessages(matching: "LAUNCH")
        #expect(launchMatches.count == 1)
        #expect(launchMatches.first?.body.contains("launch") == true)

        let pizzaMatches = session.filteredMessages(matching: "pizza")
        #expect(pizzaMatches.count == 1)
        #expect(pizzaMatches.first?.role == .pace)
    }

    // MARK: - Local history reader text parsing

    @Test func localHistoryReaderSplitsUserAndPaceFromDocumentText() async throws {
        let (userText, paceText) = PaceLocalChatHistoryReader.splitUserAndPace(
            "User: hi there\nPace: hi back"
        )
        #expect(userText == "hi there")
        #expect(paceText == "hi back")
    }

    @Test func localHistoryReaderHandlesMissingPaceMarker() async throws {
        let (userText, paceText) = PaceLocalChatHistoryReader.splitUserAndPace(
            "User: only the user said something"
        )
        #expect(userText == "only the user said something")
        #expect(paceText == "")
    }
}
