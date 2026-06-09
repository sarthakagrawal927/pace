//
//  PaceActionTagParserTests.swift
//  leanring-buddyTests
//
//  Tests for the pure-function parser that pulls action tags out of
//  Claude's response. Covers: each tag type, screen suffix, modifier
//  chains, multi-tag order preservation, and the no-tag passthrough.
//

import Foundation
import Testing
@testable import Pace

struct PaceActionTagParserTests {

    @Test func plainTextWithNoTagsPassesThroughUnchanged() async throws {
        let inputResponse = "hey there, html stands for hypertext markup language."
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == inputResponse)
        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.firstClickVisualisationLocation == nil)
    }

    @Test func pointTagIsNotConsumedByActionParser() async throws {
        // The POINT tag is owned by the existing pointing parser. The
        // action parser must leave it alone so the two layers compose.
        let inputResponse = "see the button up top. [POINT:285,11:source control]"
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == inputResponse)
        #expect(parseResult.actions.isEmpty)
    }

    @Test func singleClickTagIsExtractedAndStripped() async throws {
        let inputResponse = "saving it now. [CLICK:400,300]"
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == "saving it now.")
        #expect(parseResult.actions.count == 1)

        guard case .click(let location) = parseResult.actions[0] else {
            Issue.record("Expected a CLICK action, got \(parseResult.actions[0])")
            return
        }
        #expect(location.xInScreenshotPixels == 400)
        #expect(location.yInScreenshotPixels == 300)
        #expect(location.screenNumber == nil)
        #expect(parseResult.firstClickVisualisationLocation?.xInScreenshotPixels == 400)
    }

    @Test func clickTagWithScreenSuffixCapturesScreenNumber() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[CLICK:120,240:screen2]")

        guard case .click(let location) = parseResult.actions.first else {
            Issue.record("Expected a CLICK action")
            return
        }
        #expect(location.xInScreenshotPixels == 120)
        #expect(location.yInScreenshotPixels == 240)
        #expect(location.screenNumber == 2)
    }

    @Test func doubleClickTagYieldsDoubleClickAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[DOUBLE_CLICK:50,75]")

        guard case .doubleClick(let location) = parseResult.actions.first else {
            Issue.record("Expected a DOUBLE_CLICK action")
            return
        }
        #expect(location.xInScreenshotPixels == 50)
        #expect(location.yInScreenshotPixels == 75)
    }

    @Test func typeTagPreservesMultiWordTextVerbatim() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "ok. [TYPE:hello world, ready?]")

        #expect(parseResult.spokenText == "ok.")
        guard case .type(let typedText) = parseResult.actions.first else {
            Issue.record("Expected a TYPE action")
            return
        }
        #expect(typedText == "hello world, ready?")
    }

    @Test func keyTagWithoutModifiersReturnsBareKey() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[KEY:Return]")

        guard case .pressKey(let keyName, let modifiers) = parseResult.actions.first else {
            Issue.record("Expected a KEY action")
            return
        }
        #expect(keyName == "return")
        #expect(modifiers.isEmpty)
    }

    @Test func keyTagWithModifierChainParsesEachModifier() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[KEY:cmd+shift+t]")

        guard case .pressKey(let keyName, let modifiers) = parseResult.actions.first else {
            Issue.record("Expected a KEY action")
            return
        }
        #expect(keyName == "t")
        #expect(modifiers.contains(.command))
        #expect(modifiers.contains(.shift))
        #expect(modifiers.count == 2)
    }

    @Test func scrollTagParsesDirectionAndAmount() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[SCROLL:down:5]")

        guard case .scroll(let direction, let amountInLines) = parseResult.actions.first else {
            Issue.record("Expected a SCROLL action")
            return
        }
        #expect(direction == .down)
        #expect(amountInLines == 5)
    }

    @Test func scrollTagWithoutAmountFallsBackToDefault() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[SCROLL:up]")

        guard case .scroll(let direction, let amountInLines) = parseResult.actions.first else {
            Issue.record("Expected a SCROLL action")
            return
        }
        #expect(direction == .up)
        #expect(amountInLines == 3) // documented default
    }

    @Test func openApplicationTagPreservesDisplayName() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "opening it. [OPEN_APP:Visual Studio Code]")

        #expect(parseResult.spokenText == "opening it.")
        guard case .openApplication(let applicationName) = parseResult.actions.first else {
            Issue.record("Expected an OPEN_APP action")
            return
        }
        #expect(applicationName == "Visual Studio Code")
    }

    @Test func volumeTagParsesDirectionAndStepCount() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[VOLUME:down:4]")

        guard case .adjustVolume(let adjustment) = parseResult.actions.first else {
            Issue.record("Expected a VOLUME action")
            return
        }
        #expect(adjustment.direction == .down)
        #expect(adjustment.stepCount == 4)
    }

    @Test func brightnessTagWithoutStepCountUsesDefault() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[BRIGHTNESS:up]")

        guard case .adjustBrightness(let adjustment) = parseResult.actions.first else {
            Issue.record("Expected a BRIGHTNESS action")
            return
        }
        #expect(adjustment.direction == .up)
        #expect(adjustment.stepCount == 2)
    }

    @Test func systemAdjustmentStepCountIsClamped() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[VOLUME:up:999]")

        guard case .adjustVolume(let adjustment) = parseResult.actions.first else {
            Issue.record("Expected a VOLUME action")
            return
        }
        #expect(adjustment.stepCount == 10)
    }

    @Test func toolCallsBlockPreservesSequentialStepsAndParallelGroups() async throws {
        let inputResponse = """
        opening both.
        <tool_calls>
        [
          [
            {"tool":"open_app","app":"Music"},
            {"tool":"open_url","url":"https://example.com"}
          ],
          [
            {"tool":"music","command":"play"}
          ]
        ]
        </tool_calls>
        """

        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == "opening both.")
        #expect(parseResult.actions.count == 3)
        #expect(parseResult.executionPlan.steps.count == 2)
        #expect(parseResult.executionPlan.steps[0].actions.count == 2)
        #expect(parseResult.executionPlan.steps[1].actions.count == 1)

        guard case .openApplication(let applicationName) = parseResult.executionPlan.steps[0].actions[0] else {
            Issue.record("Expected first parallel action to open an app")
            return
        }
        #expect(applicationName == "Music")

        guard case .openURL(let urlString) = parseResult.executionPlan.steps[0].actions[1] else {
            Issue.record("Expected second parallel action to open a URL")
            return
        }
        #expect(urlString == "https://example.com")

        guard case .controlMusic(let musicCommand) = parseResult.executionPlan.steps[1].actions[0] else {
            Issue.record("Expected second sequential step to control Music")
            return
        }
        #expect(musicCommand == .play)
    }

    @Test func calendarAndReminderToolCallsParseIntoReadableTools() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        checking and saving it.
        <tool_calls>
        [
          [
            {"tool":"calendar","range":"today"}
          ],
          [
            {"tool":"reminder","title":"send the invoice"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.actions.count == 2)

        guard case .listCalendarEvents(let calendarQuery) = parseResult.actions[0] else {
            Issue.record("Expected a calendar list action")
            return
        }
        #expect(calendarQuery.range == .today)

        guard case .createReminder(let reminderRequest) = parseResult.actions[1] else {
            Issue.record("Expected a reminder creation action")
            return
        }
        #expect(reminderRequest.title == "send the invoice")
    }

    @Test func calendarCreateToolCallParsesIntoCalendarEventAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        scheduling it.
        <tool_calls>
        [
          [
            {
              "tool":"calendar_create",
              "title":"Design review",
              "start":"2026-06-10T15:00:00-07:00",
              "end":"2026-06-10T16:00:00-07:00",
              "location":"Zoom"
            }
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.spokenText == "scheduling it.")
        #expect(parseResult.actions.count == 1)

        guard case .createCalendarEvent(let calendarEventRequest) = parseResult.actions.first else {
            Issue.record("Expected calendar_create to become createCalendarEvent")
            return
        }

        #expect(calendarEventRequest.title == "Design review")
        #expect(calendarEventRequest.location == "Zoom")
        #expect(calendarEventRequest.isAllDay == false)
    }

    @Test func clipboardReadToolCallParsesIntoReadClipboardAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        checking the clipboard.
        <tool_calls>
        [
          [
            {"tool":"clipboard_read"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.spokenText == "checking the clipboard.")
        guard case .readClipboard = parseResult.actions.first else {
            Issue.record("Expected clipboard_read to become readClipboard")
            return
        }
    }

    @Test func setValueToolCallParsesIntoSetTextValueAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        rewriting it.
        <tool_calls>
        [
          [
            {"tool":"set_value","text":"new text","action":"selection"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.spokenText == "rewriting it.")
        guard case .setTextValue(let setTextValueRequest) = parseResult.actions.first else {
            Issue.record("Expected set_value to become setTextValue")
            return
        }

        #expect(setTextValueRequest.value == "new text")
        #expect(setTextValueRequest.target == .selection)
    }

    @Test func undoToolCallParsesIntoUndoLastMutationAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        undoing it.
        <tool_calls>
        [
          [
            {"tool":"undo_last"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.spokenText == "undoing it.")
        guard case .undoLastMutation = parseResult.actions.first else {
            Issue.record("Expected undo_last to become undoLastMutation")
            return
        }
    }

    @Test func windowSnapToolCallParsesIntoWindowSnapAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        snapping it.
        <tool_calls>
        [
          [
            {"tool":"window_snap","position":"right_half"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.spokenText == "snapping it.")
        guard case .snapWindow(let snapWindowRequest) = parseResult.actions.first else {
            Issue.record("Expected window_snap to become snapWindow")
            return
        }

        #expect(snapWindowRequest.position == .right)
    }

    @Test func chainedActionTagsPreserveSourceOrder() async throws {
        let inputResponse = "on it. [CLICK:740,80][TYPE:whisper flow][OPEN_APP:Safari][KEY:Return]"
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == "on it.")
        #expect(parseResult.actions.count == 4)

        if case .click(let firstLocation) = parseResult.actions[0] {
            #expect(firstLocation.xInScreenshotPixels == 740)
            #expect(firstLocation.yInScreenshotPixels == 80)
        } else {
            Issue.record("First action should be CLICK")
        }

        if case .type(let typedText) = parseResult.actions[1] {
            #expect(typedText == "whisper flow")
        } else {
            Issue.record("Second action should be TYPE")
        }

        if case .openApplication(let applicationName) = parseResult.actions[2] {
            #expect(applicationName == "Safari")
        } else {
            Issue.record("Third action should be OPEN_APP")
        }

        if case .pressKey(let keyName, _) = parseResult.actions[3] {
            #expect(keyName == "return")
        } else {
            Issue.record("Fourth action should be KEY")
        }
    }

    @Test func firstClickIsReportedForCursorFlightVisualisation() async throws {
        // The first CLICK or DOUBLE_CLICK should be exposed so the
        // existing cursor-flight visualisation has a target.
        let parseResult = PaceActionTagParser.parseActions(
            from: "[TYPE:no click yet][CLICK:200,150][CLICK:9,9]"
        )

        #expect(parseResult.firstClickVisualisationLocation?.xInScreenshotPixels == 200)
        #expect(parseResult.firstClickVisualisationLocation?.yInScreenshotPixels == 150)
    }

    @Test func tagsInterleavedWithSentencesAreAllStripped() async throws {
        let parseResult = PaceActionTagParser.parseActions(
            from: "first i'll click here [CLICK:100,200] then type [TYPE:hi] done."
        )

        #expect(parseResult.spokenText == "first i'll click here  then type  done.")
        #expect(parseResult.actions.count == 2)
    }

    @Test func unknownTagBodyIsTreatedAsAbsent() async throws {
        // [CLICK:nonsense] has no parseable x,y so it should not produce
        // an action and should not appear in the spoken text either.
        let parseResult = PaceActionTagParser.parseActions(from: "ok. [CLICK:nonsense]")

        // The tag is still stripped because the regex matched, but the
        // payload didn't parse so no action was emitted.
        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.spokenText == "ok.")
    }

    @Test func appleAppToolCallsParseIntoLocalTools() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        setting that up.
        <tool_calls>
        [
          [
            {"tool":"finder","path":"~/Downloads","action":"reveal"},
            {"tool":"notes","title":"Idea","body":"Build the Pace registry"}
          ],
          [
            {"tool":"mail","to":"alex@example.com","subject":"Hello","body":"Draft only"},
            {"tool":"things","title":"Follow up","notes":"from Pace"}
          ],
          [
            {"tool":"shortcuts","name":"Morning"},
            {"tool":"messages","recipient":"Alex","text":"Draft text"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.spokenText == "setting that up.")
        #expect(parseResult.actions.count == 6)
        #expect(parseResult.executionPlan.steps.count == 3)

        guard case .finder(let finderRequest) = parseResult.actions[0] else {
            Issue.record("Expected Finder action")
            return
        }
        #expect(finderRequest.path == "~/Downloads")
        #expect(finderRequest.action == .reveal)

        guard case .createNote(let noteRequest) = parseResult.actions[1] else {
            Issue.record("Expected Notes action")
            return
        }
        #expect(noteRequest.title == "Idea")
        #expect(noteRequest.body == "Build the Pace registry")

        guard case .composeMail(let mailDraft) = parseResult.actions[2] else {
            Issue.record("Expected Mail action")
            return
        }
        #expect(mailDraft.recipients == ["alex@example.com"])
        #expect(mailDraft.subject == "Hello")

        guard case .createThingsToDo(let thingsRequest) = parseResult.actions[3] else {
            Issue.record("Expected Things action")
            return
        }
        #expect(thingsRequest.title == "Follow up")
        #expect(thingsRequest.notes == "from Pace")

        guard case .runShortcut(let shortcutName) = parseResult.actions[4] else {
            Issue.record("Expected Shortcuts action")
            return
        }
        #expect(shortcutName == "Morning")

        guard case .openMessages(let messageRequest) = parseResult.actions[5] else {
            Issue.record("Expected Messages action")
            return
        }
        #expect(messageRequest.recipient == "Alex")
        #expect(messageRequest.text == "Draft text")
    }

    @Test func v10MailDraftPayloadParsesIntoExistingMailAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Drafting that now.",
          "intent": "action",
          "payload": {
            "name": "Mail.draft",
            "args": {
              "to": ["alex@example.com", "priya@example.com"],
              "subject": "Project status",
              "body": "Quick update: the local planner path is wired."
            }
          }
        }
        """)

        #expect(parseResult.spokenText == "Drafting that now.")
        #expect(parseResult.actions.count == 1)
        #expect(parseResult.executionPlan.steps.count == 1)

        guard case .composeMail(let mailDraft) = parseResult.actions[0] else {
            Issue.record("Expected v10 Mail.draft to become a composeMail action")
            return
        }

        #expect(mailDraft.recipients == ["alex@example.com", "priya@example.com"])
        #expect(mailDraft.subject == "Project status")
        #expect(mailDraft.body == "Quick update: the local planner path is wired.")
    }

    @Test func v10MailDraftPayloadAcceptsCommaSeparatedRecipientString() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Opening a draft.",
          "intent": "action",
          "payload": {
            "name": "mail.compose",
            "args": {
              "to": "alex@example.com, priya@example.com",
              "title": "Hello",
              "text": "Draft body"
            }
          }
        }
        """)

        guard case .composeMail(let mailDraft) = parseResult.actions.first else {
            Issue.record("Expected v10 mail.compose to become a composeMail action")
            return
        }

        #expect(mailDraft.recipients == ["alex@example.com", "priya@example.com"])
        #expect(mailDraft.subject == "Hello")
        #expect(mailDraft.body == "Draft body")
    }

    @Test func streamingMailDraftDetectorEmitsBodyChangesFromIncompleteV10JSON() async throws {
        let detector = PaceStreamingMailDraftDetector()

        let firstSnapshot = detector.detectChange(in: #"""
        {"spokenText":"Opening a draft.","intent":"action","payload":{"name":"Mail.draft","args":{"to":["alex@example.com"],"subject":"Project status","body":"Quick update
        """#)

        #expect(firstSnapshot?.recipients == ["alex@example.com"])
        #expect(firstSnapshot?.subject == "Project status")
        #expect(firstSnapshot?.body == "Quick update")

        let duplicateSnapshot = detector.detectChange(in: #"""
        {"spokenText":"Opening a draft.","intent":"action","payload":{"name":"Mail.draft","args":{"to":["alex@example.com"],"subject":"Project status","body":"Quick update
        """#)
        #expect(duplicateSnapshot == nil)

        let secondSnapshot = detector.detectChange(in: #"""
        {"spokenText":"Opening a draft.","intent":"action","payload":{"name":"Mail.draft","args":{"to":["alex@example.com"],"subject":"Project status","body":"Quick update: the local path streams.
        """#)

        #expect(secondSnapshot?.body == "Quick update: the local path streams.")
    }

    @Test func streamingMailDraftDetectorIgnoresNonMailPlannerJSON() async throws {
        let detector = PaceStreamingMailDraftDetector()
        let snapshot = detector.detectChange(in: #"""
        {"spokenText":"Opening Safari.","intent":"action","payload":{"name":"App.launch","args":{"name":"Safari"}}}
        """#)

        #expect(snapshot == nil)
    }

    @Test func actionPlanCanRemoveFirstStreamedMailDraftWithoutDroppingOtherActions() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .composeMail(PaceMailDraft(
                recipients: ["alex@example.com"],
                subject: "Status",
                body: "Draft body"
            )),
            .openApplication("Calendar")
        ])

        let filteredPlan = actionPlan.removingFirstMailDraftAction()

        #expect(filteredPlan.flattenedActions.count == 1)
        guard case .openApplication(let applicationName) = filteredPlan.flattenedActions.first else {
            Issue.record("Expected non-mail action to remain")
            return
        }
        #expect(applicationName == "Calendar")
    }

    @Test func v10SupportedLocalPayloadsMapToExistingActionCases() async throws {
        let appLaunchResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"Opening Safari.","intent":"action","payload":{"name":"App.launch","args":{"name":"Safari"}}}
        """)

        guard case .openApplication(let applicationName) = appLaunchResult.actions.first else {
            Issue.record("Expected App.launch to become openApplication")
            return
        }
        #expect(applicationName == "Safari")

        let reminderResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"Adding that.","intent":"action","payload":{"name":"Reminders.add","args":{"title":"send invoice","notes":"today"}}}
        """)

        guard case .createReminder(let reminderRequest) = reminderResult.actions.first else {
            Issue.record("Expected Reminders.add to become createReminder")
            return
        }
        #expect(reminderRequest.title == "send invoice")
        #expect(reminderRequest.notes == "today")
    }

    @Test func v10MultiCallPayloadParsesIntoSerialExecutionPlan() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Opening Safari and turning the volume down.",
          "intent": "action",
          "payload": {
            "calls": [
              {"name":"App.launch","args":{"name":"Safari"}},
              {"name":"Volume.adjust","args":{"direction":"down","steps":2}}
            ]
          }
        }
        """)

        #expect(parseResult.actions.count == 2)
        #expect(parseResult.executionPlan.steps.count == 2)

        guard case .openApplication(let applicationName) = parseResult.actions[0] else {
            Issue.record("Expected first typed call to open Safari")
            return
        }
        #expect(applicationName == "Safari")

        guard case .adjustVolume(let adjustment) = parseResult.actions[1] else {
            Issue.record("Expected second typed call to adjust volume")
            return
        }
        #expect(adjustment.direction == .down)
        #expect(adjustment.stepCount == 2)
    }

    @Test func v10DictateAndEditIntentsBecomeTypeActions() async throws {
        let dictateResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"","intent":"dictate","payload":{"text":"hello from pace","target":"focused"}}
        """)

        guard case .type(let dictatedText) = dictateResult.actions.first else {
            Issue.record("Expected dictate intent to become a type action")
            return
        }
        #expect(dictatedText == "Hello from pace")

        let proseDictateResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"","intent":"dictate","payload":{"text":"lets ship local only comma no cloud fallback","target":"focused"}}
        """)

        guard case .type(let cleanedProseText) = proseDictateResult.actions.first else {
            Issue.record("Expected prose dictate intent to become a type action")
            return
        }
        #expect(cleanedProseText == "Let's ship local only, no cloud fallback")

        let codeDictateResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"","intent":"dictate","payload":{"text":"parse action payload open paren args close paren","mode":"code","target":"focused"}}
        """)

        guard case .type(let cleanedCodeText) = codeDictateResult.actions.first else {
            Issue.record("Expected code dictate intent to become a type action")
            return
        }
        #expect(cleanedCodeText == "parseActionPayload(args)")

        let editResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"rewriting that.","intent":"edit","payload":{"replacement":"shorter version","target":"selection"}}
        """)

        guard case .setTextValue(let setTextValueRequest) = editResult.actions.first else {
            Issue.record("Expected edit intent to become a setTextValue action")
            return
        }
        #expect(setTextValueRequest.value == "shorter version")
        #expect(setTextValueRequest.target == .selection)
        #expect(editResult.spokenText == "rewriting that.")

        let commandEditResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"editing that.","intent":"edit","payload":{"command":"make this shorter","target":"selection"}}
        """)

        guard case .editSelectedText(let voiceEditRequest) = commandEditResult.actions.first else {
            Issue.record("Expected command edit intent to become an editSelectedText action")
            return
        }
        #expect(voiceEditRequest.operation == .shorten)
        #expect(commandEditResult.spokenText == "editing that.")
    }

    @Test func v10ClickAndKeyPayloadsMapToExistingInputActions() async throws {
        let clickResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"clicking it.","intent":"action","payload":{"name":"AX.press","args":{"x":120,"y":240,"screen":2}}}
        """)

        guard case .click(let clickLocation) = clickResult.actions.first else {
            Issue.record("Expected AX.press with coordinates to become click")
            return
        }
        #expect(clickLocation.xInScreenshotPixels == 120)
        #expect(clickLocation.yInScreenshotPixels == 240)
        #expect(clickLocation.screenNumber == 2)

        let clickCandidatesResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"clicking the best match.","intent":"action","payload":{"name":"AX.press","args":{"screen":1,"expectStateChange":false,"candidates":[{"x":100,"y":120,"label":"Save","confidence":0.4,"lastSeenMsAgo":"250"},{"x":300,"y":120,"label":"Save Draft","confidence":0.9,"recentRank":2}]}}}
        """)

        guard case .clickCandidates(let clickCandidateSet) = clickCandidatesResult.actions.first else {
            Issue.record("Expected AX.press candidates to become clickCandidates")
            return
        }
        #expect(clickCandidateSet.candidates.count == 2)
        #expect(clickCandidateSet.clickCount == 1)
        #expect(clickCandidateSet.candidates[0].location?.screenNumber == 1)
        #expect(clickCandidateSet.candidates[0].expectStateChange == false)
        #expect((clickCandidateSet.candidates[0].recency?.scoreBoost ?? 0) > 0)
        #expect((clickCandidateSet.candidates[1].recency?.scoreBoost ?? 0) > 0)
        #expect(clickCandidatesResult.firstClickVisualisationLocation?.xInScreenshotPixels == 100)

        let labelOnlyClickCandidatesResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"clicking submit.","intent":"action","payload":{"name":"AX.press","args":{"candidates":[{"label":"Submit","confidence":0.7},{"label":"Submit and continue","confidence":0.4}]}}}
        """)

        guard case .clickCandidates(let labelOnlyClickCandidateSet) = labelOnlyClickCandidatesResult.actions.first else {
            Issue.record("Expected label-only AX.press candidates to become clickCandidates")
            return
        }
        #expect(labelOnlyClickCandidateSet.candidates.count == 2)
        #expect(labelOnlyClickCandidateSet.candidates[0].label == "Submit")
        #expect(labelOnlyClickCandidateSet.candidates[0].location == nil)
        #expect(labelOnlyClickCandidatesResult.firstClickVisualisationLocation == nil)

        let keyResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"saving.","intent":"action","payload":{"name":"Key.press","args":{"key":"cmd+s"}}}
        """)

        guard case .pressKey(let keyName, let modifiers) = keyResult.actions.first else {
            Issue.record("Expected Key.press to become pressKey")
            return
        }
        #expect(keyName == "s")
        #expect(modifiers == [.command])

        let setValueResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"updating it.","intent":"action","payload":{"name":"AX.setValue","args":{"value":"replacement text","target":"focused"}}}
        """)

        guard case .setTextValue(let setTextValueRequest) = setValueResult.actions.first else {
            Issue.record("Expected AX.setValue to become setTextValue")
            return
        }
        #expect(setTextValueRequest.value == "replacement text")
        #expect(setTextValueRequest.target == .focused)

        let undoResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"Undoing that.","intent":"action","payload":{"name":"Undo.last","args":{}}}
        """)

        guard case .undoLastMutation = undoResult.actions.first else {
            Issue.record("Expected Undo.last to become undoLastMutation")
            return
        }

        let clipboardResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"Reading the clipboard.","intent":"action","payload":{"name":"Clipboard.read","args":{}}}
        """)

        guard case .readClipboard = clipboardResult.actions.first else {
            Issue.record("Expected Clipboard.read to become readClipboard")
            return
        }
    }

    @Test func v10NotesMessagesAndMCPPayloadsParse() async throws {
        let notesResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"searching notes.","intent":"action","payload":{"name":"Notes.search","args":{"query":"roadmap"}}}
        """)

        guard case .searchNotes(let query) = notesResult.actions.first else {
            Issue.record("Expected Notes.search to become searchNotes")
            return
        }
        #expect(query == "roadmap")

        let messagesResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"opening messages.","intent":"action","payload":{"name":"Messages.open","args":{"recipient":"Alex","text":"running late"}}}
        """)

        guard case .openMessages(let messageRequest) = messagesResult.actions.first else {
            Issue.record("Expected Messages.open to become openMessages")
            return
        }
        #expect(messageRequest.recipient == "Alex")
        #expect(messageRequest.text == "running late")

        let mcpResult = PaceActionTagParser.parseActions(from: """
        {"spokenText":"calling altic.","intent":"action","payload":{"name":"MCP.call","args":{"server":"altic","tool":"notes_create","arguments":{"title":"Idea","body":"text"}}}}
        """)

        guard case .mcp(let mcpToolCall) = mcpResult.actions.first else {
            Issue.record("Expected MCP.call to become mcp")
            return
        }
        #expect(mcpToolCall.serverName == "altic")
        #expect(mcpToolCall.toolName == "notes_create")
        #expect(mcpToolCall.arguments["title"] == .string("Idea"))
    }

    @Test func v10AnswerIntentKeepsSpeechAndEmitsNoActions() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "HTML stands for hypertext markup language.",
          "intent": "answer",
          "payload": {"answer": "HTML stands for hypertext markup language."}
        }
        """)

        #expect(parseResult.spokenText == "HTML stands for hypertext markup language.")
        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.executionPlan.steps.isEmpty)
    }

    @Test func v10CalendarCreateEventPayloadParsesIntoCalendarEventAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Adding that to your calendar.",
          "intent": "action",
          "payload": {
            "name": "Calendar.createEvent",
            "args": {
              "title": "Launch review",
              "start": "2026-06-10T15:00:00-07:00",
              "end": "2026-06-10T16:00:00-07:00",
              "location": "Zoom",
              "notes": "Review launch checklist"
            }
          }
        }
        """)

        #expect(parseResult.spokenText == "Adding that to your calendar.")
        #expect(parseResult.actions.count == 1)

        guard case .createCalendarEvent(let calendarEventRequest) = parseResult.actions.first else {
            Issue.record("Expected Calendar.createEvent to become createCalendarEvent")
            return
        }

        #expect(calendarEventRequest.title == "Launch review")
        #expect(calendarEventRequest.isAllDay == false)
        #expect(calendarEventRequest.location == "Zoom")
        #expect(calendarEventRequest.notes == "Review launch checklist")
        #expect(calendarEventRequest.endDate > calendarEventRequest.startDate)
    }

    @Test func v10CalendarCreateEventDateOnlyPayloadCreatesAllDayEvent() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Adding that all-day event.",
          "intent": "action",
          "payload": {
            "name": "calendar.create",
            "args": {"title": "Launch day", "date": "2026-06-10"}
          }
        }
        """)

        guard case .createCalendarEvent(let calendarEventRequest) = parseResult.actions.first else {
            Issue.record("Expected date-only calendar payload to become createCalendarEvent")
            return
        }

        #expect(calendarEventRequest.title == "Launch day")
        #expect(calendarEventRequest.isAllDay == true)
    }

    @Test func v10WindowSnapPayloadParsesIntoWindowSnapAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Snapping it left.",
          "intent": "action",
          "payload": {
            "name": "Window.snap",
            "args": {"position": "left"}
          }
        }
        """)

        #expect(parseResult.spokenText == "Snapping it left.")
        guard case .snapWindow(let snapWindowRequest) = parseResult.actions.first else {
            Issue.record("Expected Window.snap to become snapWindow")
            return
        }

        #expect(snapWindowRequest.position == .left)
    }

    @Test func v10UnsupportedActionKeepsSpeechAndEmitsNoActions() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "I cannot do that locally yet.",
          "intent": "action",
          "payload": {
            "name": "Clipboard.write",
            "args": {"text": "nope"}
          }
        }
        """)

        #expect(parseResult.spokenText == "I cannot do that locally yet.")
        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.executionPlan.steps.isEmpty)
    }

    @Test func v10SchemaInvalidPlannerEnvelopeEmitsNoActions() async throws {
        let missingSpokenTextResult = PaceActionTagParser.parseActions(from: """
        {
          "intent": "action",
          "payload": {
            "name": "App.launch",
            "args": {"name": "Safari"}
          }
        }
        """)

        #expect(missingSpokenTextResult.spokenText == "")
        #expect(missingSpokenTextResult.actions.isEmpty)
        #expect(missingSpokenTextResult.executionPlan.steps.isEmpty)

        let invalidIntentResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Opening Safari.",
          "intent": 42,
          "payload": {
            "name": "App.launch",
            "args": {"name": "Safari"}
          }
        }
        """)

        #expect(invalidIntentResult.spokenText == "Opening Safari.")
        #expect(invalidIntentResult.actions.isEmpty)
        #expect(invalidIntentResult.executionPlan.steps.isEmpty)
    }

    @Test func v10SchemaInvalidPlannerCallsEmitNoActions() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Opening Safari.",
          "intent": "action",
          "payload": {
            "calls": [
              {"name": "App.launch", "args": {"name": "Safari"}, "extra": true}
            ]
          }
        }
        """)

        #expect(parseResult.spokenText == "Opening Safari.")
        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.executionPlan.steps.isEmpty)
    }

    @Test func v10InvalidParameterizedPayloadsAreRejectedBeforeExecution() async throws {
        let invalidCalendarResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "I need a date first.",
          "intent": "action",
          "payload": {
            "name": "Calendar.createEvent",
            "args": {"title": "Planning"}
          }
        }
        """)

        #expect(invalidCalendarResult.spokenText == "I need a date first.")
        #expect(invalidCalendarResult.actions.isEmpty)
        #expect(invalidCalendarResult.executionPlan.steps.isEmpty)

        let invalidKeyResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "I cannot press that key.",
          "intent": "action",
          "payload": {
            "name": "Key.press",
            "args": {"key": "cmd+notakey"}
          }
        }
        """)

        #expect(invalidKeyResult.spokenText == "I cannot press that key.")
        #expect(invalidKeyResult.actions.isEmpty)
        #expect(invalidKeyResult.executionPlan.steps.isEmpty)
    }

    @Test func arbitraryJSONWithoutPlannerFieldsFallsBackToPlainText() async throws {
        let inputResponse = #"{"status":"ok","message":"not a planner response"}"#
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == inputResponse)
        #expect(parseResult.actions.isEmpty)
    }

    @Test func registryProvidesPlannerPromptEntriesAndRiskLabels() async throws {
        #expect(PaceToolRegistry.validateLocalRegistry().isEmpty)
        #expect(PaceToolRegistry.validateSourceRegistryArtifact().isEmpty)
        #expect(PaceToolRegistry.localTools.count == PaceLocalToolKind.allCases.count)

        #expect(PaceToolRegistry.kind(forToolName: "open-website") == .openURL)
        #expect(PaceToolRegistry.kind(forToolName: "run_shortcut") == .shortcuts)
        #expect(PaceToolRegistry.kind(forToolName: "calendar_event") == .calendarCreate)
        #expect(PaceToolRegistry.kind(forToolName: "clipboard") == .clipboard)
        #expect(PaceToolRegistry.kind(forToolName: "ax_set_value") == .setValue)
        #expect(PaceToolRegistry.kind(forToolName: "undo") == .undo)
        #expect(PaceToolRegistry.kind(forToolName: "snap_window") == .window)
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"notes""#))
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"things""#))
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"calendar_create""#))
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"clipboard_read""#))
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"set_value""#))
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"undo_last""#))
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"window_snap""#))

        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .listCalendarEvents(PaceCalendarQuery(range: .today)),
            .readClipboard,
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .setTextValue(PaceSetTextValueRequest(
                value: "hello",
                target: .focused
            )),
            .undoLastMutation,
            .createCalendarEvent(PaceCalendarEventRequest(
                title: "Design review",
                startDate: Date(timeIntervalSince1970: 1_780_000_000),
                endDate: Date(timeIntervalSince1970: 1_780_003_600),
                isAllDay: false,
                notes: nil,
                location: nil,
                calendarTitle: nil
            )),
            .type("hello")
        ])
        #expect(actionPlan.approvalSummary.contains("[read-only]"))
        #expect(actionPlan.approvalSummary.contains("[app/system change]"))
        #expect(actionPlan.approvalSummary.contains("[input injection]"))
    }

    @Test func noteApprovalSummaryIncludesBodyPreview() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .createNote(PaceNoteRequest(title: "Idea", body: "Build the Pace registry"))
        ])

        #expect(actionPlan.approvalSummary.contains("Create note: Idea"))
        #expect(actionPlan.approvalSummary.contains("Build the Pace registry"))
    }

    @Test func notesToolParsesAppendAndSearchActions() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        handling notes.
        <tool_calls>
        [
          [
            {"tool":"notes","action":"append","title":"Idea","body":"Add this line"},
            {"tool":"notes","action":"search","query":"roadmap"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.actions.count == 2)

        guard case .appendNote(let appendRequest) = parseResult.actions[0] else {
            Issue.record("Expected append note action")
            return
        }
        #expect(appendRequest.title == "Idea")
        #expect(appendRequest.body == "Add this line")

        guard case .searchNotes(let query) = parseResult.actions[1] else {
            Issue.record("Expected search notes action")
            return
        }
        #expect(query == "roadmap")
    }

    @Test func registryIncludesRequestedLocalToolAllowList() async throws {
        let requestedToolNames = [
            "open_app",
            "open_url",
            "music",
            "volume",
            "brightness",
            "calendar",
            "reminder",
            "finder",
            "notes",
        ]

        for toolName in requestedToolNames {
            #expect(PaceToolRegistry.kind(forToolName: toolName) != nil, "expected \(toolName) in local tool allow-list")
            #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"\#(toolName)""#))
        }
    }

    @Test func mcpToolCallsParseWithWrapperShape() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        calling the external tool.
        <tool_calls>
        [
          [
            {
              "tool":"mcp",
              "server":"altic",
              "name":"notes_create",
              "arguments":{"title":"Idea","body":"from MCP"}
            }
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.actions.count == 1)

        guard case .mcp(let mcpToolCall) = parseResult.actions[0] else {
            Issue.record("Expected MCP action")
            return
        }

        #expect(mcpToolCall.serverName == "altic")
        #expect(mcpToolCall.toolName == "notes_create")
        #expect(mcpToolCall.arguments["title"] == .string("Idea"))
        #expect(mcpToolCall.arguments["body"] == .string("from MCP"))
        #expect(parseResult.spokenText == "calling the external tool.")
    }

    @Test func mcpToolCallsParseWithServerQualifiedNativeToolShape() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        searching notes.
        <tool_calls>
        [
          [
            {"tool":"notes_search","server":"altic","query":"roadmap","limit":5}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.actions.count == 1)

        guard case .mcp(let mcpToolCall) = parseResult.actions[0] else {
            Issue.record("Expected MCP action")
            return
        }

        #expect(mcpToolCall.serverName == "altic")
        #expect(mcpToolCall.toolName == "notes_search")
        #expect(mcpToolCall.arguments["query"] == .string("roadmap"))
        #expect(mcpToolCall.arguments["limit"] == .number(5))
    }

    @Test func invalidRegistryToolCallsAreRejectedBeforeExecution() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        I cannot safely run those.
        <tool_calls>
        [
          [
            {"tool":"open_url"},
            {"tool":"scroll","direction":"sideways"},
            {"tool":"mail"},
            {"tool":"calendar","action":"create","title":"Planning"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.spokenText == "I cannot safely run those.")
    }

    @Test func registryToolCallValidationAcceptsV10ValueFieldForSetValue() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        updating the field.
        <tool_calls>
        [
          [
            {"tool":"set_value","value":"replacement text","target":"selection"}
          ]
        ]
        </tool_calls>
        """)

        #expect(parseResult.actions.count == 1)

        guard case .setTextValue(let setTextValueRequest) = parseResult.actions.first else {
            Issue.record("Expected valid set_value tool call to become setTextValue")
            return
        }

        #expect(setTextValueRequest.value == "replacement text")
        #expect(setTextValueRequest.target == .selection)
    }

    @Test func fastActionParserRecognizesKnownApplicationLaunches() async throws {
        let parseResult = PaceFastActionCommandParser.parse(transcript: "open Raycast")

        #expect(parseResult?.spokenText == "opening Raycast.")
        #expect(parseResult?.executionPlan.steps.count == 1)

        guard let firstAction = parseResult?.executionPlan.flattenedActions.first,
              case .openApplication(let applicationName) = firstAction else {
            Issue.record("Expected fast parser to emit an openApplication action")
            return
        }

        #expect(applicationName == "Raycast")
    }

    @Test func fastActionParserRecognizesURLLaunches() async throws {
        let parseResult = PaceFastActionCommandParser.parse(transcript: "go to raycast.com")

        guard let firstAction = parseResult?.executionPlan.flattenedActions.first,
              case .openURL(let urlString) = firstAction else {
            Issue.record("Expected fast parser to emit an openURL action")
            return
        }

        #expect(urlString == "https://raycast.com")
        #expect(parseResult?.spokenText == "opening https://raycast.com.")
    }

    @Test func fastActionParserRecognizesMusicAndSystemAdjustments() async throws {
        let musicResult = PaceFastActionCommandParser.parse(transcript: "next song")
        guard let musicAction = musicResult?.executionPlan.flattenedActions.first,
              case .controlMusic(let musicCommand) = musicAction else {
            Issue.record("Expected fast parser to emit a music action")
            return
        }
        #expect(musicCommand == .next)

        let volumeResult = PaceFastActionCommandParser.parse(transcript: "turn volume down 4")
        guard let volumeAction = volumeResult?.executionPlan.flattenedActions.first,
              case .adjustVolume(let volumeAdjustment) = volumeAction else {
            Issue.record("Expected fast parser to emit a volume action")
            return
        }
        #expect(volumeAdjustment.direction == .down)
        #expect(volumeAdjustment.stepCount == 4)

        let brightnessResult = PaceFastActionCommandParser.parse(transcript: "brightness up")
        guard let brightnessAction = brightnessResult?.executionPlan.flattenedActions.first,
              case .adjustBrightness(let brightnessAdjustment) = brightnessAction else {
            Issue.record("Expected fast parser to emit a brightness action")
            return
        }
        #expect(brightnessAdjustment.direction == .up)
        #expect(brightnessAdjustment.stepCount == 2)
    }

    @Test func fastActionParserRecognizesUndoCommands() async throws {
        let parseResult = PaceFastActionCommandParser.parse(transcript: "undo that")

        #expect(parseResult?.spokenText == "undoing that.")
        guard let firstAction = parseResult?.executionPlan.flattenedActions.first,
              case .undoLastMutation = firstAction else {
            Issue.record("Expected fast parser to emit an undoLastMutation action")
            return
        }
    }

    @Test func fastActionParserRecognizesSelectedTextEditCommands() async throws {
        let parseResult = PaceFastActionCommandParser.parse(transcript: "make this shorter")

        #expect(parseResult?.spokenText == "editing selection.")
        guard let firstAction = parseResult?.executionPlan.flattenedActions.first,
              case .editSelectedText(let voiceEditRequest) = firstAction else {
            Issue.record("Expected fast parser to emit an editSelectedText action")
            return
        }

        #expect(voiceEditRequest.operation == .shorten)

        let replaceResult = PaceFastActionCommandParser.parse(transcript: "replace sarthak with team")
        guard let replaceAction = replaceResult?.executionPlan.flattenedActions.first,
              case .editSelectedText(let replaceRequest) = replaceAction else {
            Issue.record("Expected replace command to emit an editSelectedText action")
            return
        }
        #expect(replaceRequest.operation == .replace(oldText: "sarthak", newText: "team"))
    }

    @Test func fastActionParserRecognizesKeyboardShortcuts() async throws {
        let saveResult = PaceFastActionCommandParser.parse(transcript: "save this")
        guard let saveAction = saveResult?.executionPlan.flattenedActions.first,
              case .pressKey(let saveKeyName, let saveModifiers) = saveAction else {
            Issue.record("Expected save command to emit a command-s key press")
            return
        }
        #expect(saveKeyName == "s")
        #expect(saveModifiers == [.command])
        #expect(saveResult?.spokenText == "saving.")

        let newTabResult = PaceFastActionCommandParser.parse(transcript: "new tab")
        guard let newTabAction = newTabResult?.executionPlan.flattenedActions.first,
              case .pressKey(let newTabKeyName, let newTabModifiers) = newTabAction else {
            Issue.record("Expected new tab command to emit a command-t key press")
            return
        }
        #expect(newTabKeyName == "t")
        #expect(newTabModifiers == [.command])

        let reopenTabResult = PaceFastActionCommandParser.parse(transcript: "reopen closed tab")
        guard let reopenTabAction = reopenTabResult?.executionPlan.flattenedActions.first,
              case .pressKey(let reopenTabKeyName, let reopenTabModifiers) = reopenTabAction else {
            Issue.record("Expected reopen tab command to emit a command-shift-t key press")
            return
        }
        #expect(reopenTabKeyName == "t")
        #expect(reopenTabModifiers == [.command, .shift])
    }

    @Test func fastActionParserRecognizesWindowSnapCommands() async throws {
        let leftResult = PaceFastActionCommandParser.parse(transcript: "snap window left")
        guard let leftAction = leftResult?.executionPlan.flattenedActions.first,
              case .snapWindow(let leftSnapWindowRequest) = leftAction else {
            Issue.record("Expected snap window left to emit a snapWindow action")
            return
        }
        #expect(leftSnapWindowRequest.position == .left)
        #expect(leftResult?.spokenText == "moving the window.")

        let maximizeResult = PaceFastActionCommandParser.parse(transcript: "maximize window")
        guard let maximizeAction = maximizeResult?.executionPlan.flattenedActions.first,
              case .snapWindow(let maximizeWindowRequest) = maximizeAction else {
            Issue.record("Expected maximize window to emit a snapWindow action")
            return
        }
        #expect(maximizeWindowRequest.position == .maximize)
    }

    @Test func fastActionParserRecognizesOpenMessagesWithoutBody() async throws {
        let openMessagesResult = PaceFastActionCommandParser.parse(transcript: "open messages to alex chen")
        guard let openMessagesAction = openMessagesResult?.executionPlan.flattenedActions.first,
              case .openMessages(let messageRequest) = openMessagesAction else {
            Issue.record("Expected open messages recipient command to emit openMessages")
            return
        }
        #expect(messageRequest.recipient == "Alex Chen")
        #expect(messageRequest.text == nil)
        #expect(openMessagesResult?.spokenText == "opening Messages for Alex Chen.")

        let bodyCommandResult = PaceFastActionCommandParser.parse(transcript: "message alex saying hi")
        let sendCommandResult = PaceFastActionCommandParser.parse(transcript: "send message to alex")

        #expect(bodyCommandResult?.executionPlan.flattenedActions.isEmpty ?? true)
        #expect(sendCommandResult?.executionPlan.flattenedActions.isEmpty ?? true)
    }

    @Test func fastActionParserDoesNotGrabAmbiguousScreenCommands() async throws {
        let ambiguousMenuResult = PaceFastActionCommandParser.parse(transcript: "open the file menu")
        let clickResult = PaceFastActionCommandParser.parse(transcript: "click the blue button")
        let scrollResult = PaceFastActionCommandParser.parse(transcript: "scroll down")
        let genericMoveResult = PaceFastActionCommandParser.parse(transcript: "move left")

        #expect(ambiguousMenuResult?.executionPlan.flattenedActions.isEmpty ?? true)
        #expect(clickResult?.executionPlan.flattenedActions.isEmpty ?? true)
        #expect(scrollResult?.executionPlan.flattenedActions.isEmpty ?? true)
        #expect(genericMoveResult?.executionPlan.flattenedActions.isEmpty ?? true)
    }
}
