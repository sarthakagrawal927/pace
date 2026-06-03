//
//  PaceActionTagParserTests.swift
//  leanring-buddyTests
//
//  Tests for the pure-function parser that pulls action tags out of
//  Claude's response. Covers: each tag type, screen suffix, modifier
//  chains, multi-tag order preservation, and the no-tag passthrough.
//

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

    @Test func registryProvidesPlannerPromptEntriesAndRiskLabels() async throws {
        #expect(PaceToolRegistry.kind(forToolName: "open-website") == .openURL)
        #expect(PaceToolRegistry.kind(forToolName: "run_shortcut") == .shortcuts)
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"notes""#))
        #expect(PaceToolRegistry.plannerToolListText.contains(#""tool":"things""#))

        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .listCalendarEvents(PaceCalendarQuery(range: .today)),
            .type("hello")
        ])
        #expect(actionPlan.approvalSummary.contains("[read-only]"))
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
}
