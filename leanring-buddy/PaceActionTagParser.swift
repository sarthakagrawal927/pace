//
//  PaceActionTagParser.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (Wave 6a split): the parser
//  that turns planner text (legacy [TAG:…] dialect and v10 typed JSON)
//  into a typed PaceActionExecutionPlan. Behavior-identical move — no
//  logic changed during extraction.
//

import Foundation

nonisolated enum PaceActionTagParser {
    private struct ToolCallBlockParseResult {
        let range: Range<String.Index>
        let steps: [PaceActionExecutionStep]
    }

    private struct OrderedActionStep {
        let sourceOffset: Int
        let parseOrder: Int
        let step: PaceActionExecutionStep
    }

    private struct PlannerResponseDTO: Decodable {
        let spokenText: String?
        let intent: String?
        let payload: [String: PaceMCPJSONValue]?
    }

    private struct ToolCallDTO: Decodable {
        let tool: String
        let app: String?
        let name: String?
        let url: String?
        let command: String?
        let direction: String?
        let title: String?
        let query: String?
        let text: String?
        let body: String?
        let notes: String?
        let range: String?
        let key: String?
        let path: String?
        let action: String?
        let to: String?
        let subject: String?
        let recipient: String?
        let server: String?
        let toolName: String?
        let mcpTool: String?
        let arguments: [String: PaceMCPJSONValue]
        let extraArguments: [String: PaceMCPJSONValue]
        let steps: Int?
        let amount: Int?
        let x: Int?
        let y: Int?
        let screen: Int?
        let candidates: [ClickCandidateDTO]
        let expectStateChange: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case tool, app, name, url, command, direction, title, query, text, body, notes, range, key, path, action, to, subject, recipient, server, toolName, mcpTool, arguments, steps, amount, x, y, screen, candidates, expectStateChange
        }

        struct ClickCandidateDTO: Decodable {
            let x: Int?
            let y: Int?
            let screen: Int?
            let label: String?
            let confidence: Double?
            let expectStateChange: Bool?
            let recencyRank: Int?
            let lastSeenMillisecondsAgo: Double?

            enum CodingKeys: String, CodingKey {
                case x, y, screen, label, confidence, expectStateChange
                case recencyRank, recentRank, lastSeenMillisecondsAgo, lastSeenMsAgo, observedMillisecondsAgo, observedMsAgo
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.x = Self.decodeIntIfPresent(from: container, forKey: .x)
                self.y = Self.decodeIntIfPresent(from: container, forKey: .y)
                self.screen = Self.decodeIntIfPresent(from: container, forKey: .screen)
                self.label = Self.decodeStringIfPresent(from: container, forKey: .label)
                self.confidence = try? container.decodeIfPresent(Double.self, forKey: .confidence)
                self.expectStateChange = try? container.decodeIfPresent(Bool.self, forKey: .expectStateChange)
                self.recencyRank = Self.firstDecodedInt(
                    from: container,
                    keys: [.recencyRank, .recentRank]
                )
                self.lastSeenMillisecondsAgo = Self.firstDecodedDouble(
                    from: container,
                    keys: [.lastSeenMillisecondsAgo, .lastSeenMsAgo, .observedMillisecondsAgo, .observedMsAgo]
                )
            }

            private static func decodeStringIfPresent(
                from container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) -> String? {
                if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                    return stringValue
                }
                if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return String(intValue)
                }
                return nil
            }

            private static func decodeIntIfPresent(
                from container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) -> Int? {
                if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return intValue
                }
                if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                    return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return nil
            }

            private static func firstDecodedInt(
                from container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> Int? {
                for key in keys {
                    if let intValue = decodeIntIfPresent(from: container, forKey: key) {
                        return intValue
                    }
                }
                return nil
            }

            private static func decodeDoubleIfPresent(
                from container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) -> Double? {
                if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
                    return doubleValue
                }
                if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return Double(intValue)
                }
                if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                    return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return nil
            }

            private static func firstDecodedDouble(
                from container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> Double? {
                for key in keys {
                    if let doubleValue = decodeDoubleIfPresent(from: container, forKey: key) {
                        return doubleValue
                    }
                }
                return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawContainer = try decoder.container(keyedBy: PaceMCPDynamicCodingKey.self)
            self.tool = try container.decode(String.self, forKey: .tool)
            self.app = Self.decodeStringIfPresent(from: container, forKey: .app)
            self.name = Self.decodeStringIfPresent(from: container, forKey: .name)
            self.url = Self.decodeStringIfPresent(from: container, forKey: .url)
            self.command = Self.decodeStringIfPresent(from: container, forKey: .command)
            self.direction = Self.decodeStringIfPresent(from: container, forKey: .direction)
            self.title = Self.decodeStringIfPresent(from: container, forKey: .title)
            self.query = Self.decodeStringIfPresent(from: container, forKey: .query)
            self.text = Self.decodeStringIfPresent(from: container, forKey: .text)
            self.body = Self.decodeStringIfPresent(from: container, forKey: .body)
            self.notes = Self.decodeStringIfPresent(from: container, forKey: .notes)
            self.range = Self.decodeStringIfPresent(from: container, forKey: .range)
            self.key = Self.decodeStringIfPresent(from: container, forKey: .key)
            self.path = Self.decodeStringIfPresent(from: container, forKey: .path)
            self.action = Self.decodeStringIfPresent(from: container, forKey: .action)
            self.to = Self.decodeStringIfPresent(from: container, forKey: .to)
            self.subject = Self.decodeStringIfPresent(from: container, forKey: .subject)
            self.recipient = Self.decodeStringIfPresent(from: container, forKey: .recipient)
            self.server = Self.decodeStringIfPresent(from: container, forKey: .server)
            self.toolName = Self.decodeStringIfPresent(from: container, forKey: .toolName)
            self.mcpTool = Self.decodeStringIfPresent(from: container, forKey: .mcpTool)
            self.arguments = (try? container.decodeIfPresent([String: PaceMCPJSONValue].self, forKey: .arguments)) ?? [:]
            self.steps = Self.decodeIntIfPresent(from: container, forKey: .steps)
            self.amount = Self.decodeIntIfPresent(from: container, forKey: .amount)
            self.x = Self.decodeIntIfPresent(from: container, forKey: .x)
            self.y = Self.decodeIntIfPresent(from: container, forKey: .y)
            self.screen = Self.decodeIntIfPresent(from: container, forKey: .screen)
            self.candidates = (try? container.decodeIfPresent([ClickCandidateDTO].self, forKey: .candidates)) ?? []
            self.expectStateChange = try? container.decodeIfPresent(Bool.self, forKey: .expectStateChange)
            self.extraArguments = Self.decodeExtraArguments(from: rawContainer)
        }

        private static func decodeStringIfPresent(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> String? {
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                return stringValue
            }
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(intValue)
            }
            return nil
        }

        private static func decodeIntIfPresent(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int? {
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return intValue
            }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        private static func decodeExtraArguments(
            from container: KeyedDecodingContainer<PaceMCPDynamicCodingKey>
        ) -> [String: PaceMCPJSONValue] {
            let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
            var extraArguments: [String: PaceMCPJSONValue] = [:]

            for key in container.allKeys where !knownKeys.contains(key.stringValue) {
                if let value = try? container.decode(PaceMCPJSONValue.self, forKey: key) {
                    extraArguments[key.stringValue] = value
                }
            }

            return extraArguments
        }
    }

    private struct PaceMCPDynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    /// Tag formats supported (case-insensitive on tag name):
    ///   [CLICK:x,y]                or [CLICK:x,y:screen2]
    ///   [DOUBLE_CLICK:x,y]         or [DOUBLE_CLICK:x,y:screen2]
    ///   [TYPE:hello world]
    ///   [KEY:Return]               or [KEY:cmd+s]   or [KEY:cmd+shift+t]
    ///   [SCROLL:up:3]              or [SCROLL:down:5]
    ///   [OPEN_APP:Safari]
    ///   [VOLUME:up:2]              or [VOLUME:down]
    ///   [BRIGHTNESS:up]            or [BRIGHTNESS:down:3]
    ///
    /// Preferred grouped format:
    ///   <tool_calls>
    ///   [[{"tool":"open_app","app":"Music"},{"tool":"music","command":"play"}]]
    ///   </tool_calls>
    ///
    /// Order of tags in the response is preserved in the returned actions array.
    static func parseActions(from responseText: String) -> PaceActionTagParseResult {
        if let plannerResponseParseResult = parsePlannerResponseJSON(from: responseText) {
            return plannerResponseParseResult
        }

        let toolCallBlocks = parseToolCallBlocks(in: responseText)
        let toolCallRanges = toolCallBlocks.map(\.range)
        let actionTagMatches = parseActionTagMatches(
            in: responseText,
            excludingRanges: toolCallRanges
        )

        var orderedSteps: [OrderedActionStep] = []
        var parseOrder = 0

        for block in toolCallBlocks {
            let sourceOffset = responseText.distance(from: responseText.startIndex, to: block.range.lowerBound)
            for step in block.steps {
                orderedSteps.append(OrderedActionStep(
                    sourceOffset: sourceOffset,
                    parseOrder: parseOrder,
                    step: step
                ))
                parseOrder += 1
            }
        }

        for match in actionTagMatches {
            guard let nameRange = Range(match.range(at: 1), in: responseText),
                  let payloadRange = Range(match.range(at: 2), in: responseText),
                  let fullMatchRange = Range(match.range, in: responseText) else {
                continue
            }
            let tagName = String(responseText[nameRange]).uppercased()
            let payload = String(responseText[payloadRange])

            guard let parsedAction = parseSingleAction(tagName: tagName, payload: payload) else {
                continue
            }

            let sourceOffset = responseText.distance(from: responseText.startIndex, to: fullMatchRange.lowerBound)
            orderedSteps.append(OrderedActionStep(
                sourceOffset: sourceOffset,
                parseOrder: parseOrder,
                step: PaceActionExecutionStep(actions: [parsedAction])
            ))
            parseOrder += 1
        }

        let executionSteps = orderedSteps
            .sorted {
                if $0.sourceOffset == $1.sourceOffset {
                    return $0.parseOrder < $1.parseOrder
                }
                return $0.sourceOffset < $1.sourceOffset
            }
            .map(\.step)
        let allActions = executionSteps.flatMap(\.actions)
        let actionTagStringRanges: [Range<String.Index>] = actionTagMatches.compactMap { match in
            Range(match.range, in: responseText)
        }
        let cleanedSpokenText = stripRanges(
            in: responseText,
            removingRanges: toolCallRanges + actionTagStringRanges
        )
        .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return PaceActionTagParseResult(
            spokenText: cleanedSpokenText,
            actions: allActions,
            executionPlan: PaceActionExecutionPlan(steps: executionSteps),
            firstClickVisualisationLocation: firstClickVisualisationLocation(in: allActions)
        )
    }

    private static func parsePlannerResponseJSON(from responseText: String) -> PaceActionTagParseResult? {
        let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedResponseText.hasPrefix("{"), trimmedResponseText.hasSuffix("}") else {
            return nil
        }
        guard let responseData = trimmedResponseText.data(using: .utf8),
              let plannerResponseObject = try? JSONDecoder().decode([String: PaceMCPJSONValue].self, from: responseData) else {
            return nil
        }
        guard plannerResponseObject.keys.contains(where: { ["spokenText", "intent", "payload"].contains($0) }) else {
            return nil
        }

        let envelopeValidationIssues = validatePlannerResponseEnvelope(plannerResponseObject)
        guard envelopeValidationIssues.isEmpty else {
            print("⚠️ Rejected invalid v10 planner response before execution: \(envelopeValidationIssues.joined(separator: "; "))")
            return PaceActionTagParseResult(
                spokenText: strictStringValue(for: "spokenText", in: plannerResponseObject) ?? "",
                actions: [],
                executionPlan: PaceActionExecutionPlan(steps: []),
                firstClickVisualisationLocation: nil
            )
        }

        guard let plannerResponse = try? JSONDecoder().decode(PlannerResponseDTO.self, from: responseData) else {
            return nil
        }

        let spokenText = plannerResponse.spokenText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedIntent = plannerResponse.intent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let payload = plannerResponse.payload,
              let plannerActions = parsePlannerActions(intent: normalizedIntent, payload: payload),
              !plannerActions.isEmpty else {
            return PaceActionTagParseResult(
                spokenText: spokenText,
                actions: [],
                executionPlan: PaceActionExecutionPlan(steps: []),
                firstClickVisualisationLocation: nil
            )
        }

        let executionPlan = PaceActionExecutionPlan.serial(actions: plannerActions)
        return PaceActionTagParseResult(
            spokenText: spokenText,
            actions: plannerActions,
            executionPlan: executionPlan,
            firstClickVisualisationLocation: firstClickVisualisationLocation(in: plannerActions)
        )
    }

    private static func validatePlannerResponseEnvelope(
        _ plannerResponseObject: [String: PaceMCPJSONValue]
    ) -> [String] {
        let allowedTopLevelKeys = Set(["spokenText", "intent", "payload"])
        var issues: [String] = []

        for unexpectedKey in Set(plannerResponseObject.keys).subtracting(allowedTopLevelKeys).sorted() {
            issues.append("unexpected top-level key \(unexpectedKey)")
        }

        guard strictStringValue(for: "spokenText", in: plannerResponseObject) != nil else {
            issues.append("spokenText must be a string")
            return issues
        }

        guard let rawIntent = strictStringValue(for: "intent", in: plannerResponseObject) else {
            issues.append("intent must be a string")
            return issues
        }

        let normalizedIntent = rawIntent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowedIntents = Set(["answer", "action", "dictate", "edit", "clarify", "refuse"])
        guard allowedIntents.contains(normalizedIntent) else {
            issues.append("intent must be one of \(allowedIntents.sorted().joined(separator: ", "))")
            return issues
        }

        let payload = objectValue(for: "payload", in: plannerResponseObject)
        if plannerResponseObject["payload"] != nil && payload == nil {
            issues.append("payload must be an object")
        }

        guard let payload else {
            if normalizedIntent == "action" {
                issues.append("action intent requires payload")
            }
            return issues
        }

        issues.append(contentsOf: validatePlannerResponsePayload(payload, intent: normalizedIntent))
        return issues
    }

    private static func validatePlannerResponsePayload(
        _ payload: [String: PaceMCPJSONValue],
        intent normalizedIntent: String
    ) -> [String] {
        var issues: [String] = []

        for key in ["name", "answer", "text", "replacement", "command"] {
            if payload[key] != nil && strictStringValue(for: key, in: payload) == nil {
                issues.append("payload.\(key) must be a string")
            }
        }

        if let target = strictStringValue(for: "target", in: payload),
           !["focused", "selection"].contains(target.lowercased()) {
            issues.append("payload.target must be focused or selection")
        } else if payload["target"] != nil && strictStringValue(for: "target", in: payload) == nil {
            issues.append("payload.target must be a string")
        }

        if payload["args"] != nil && objectValue(for: "args", in: payload) == nil {
            issues.append("payload.args must be an object")
        }

        if let callsIssue = validatePlannerResponseCallsPayload(payload["calls"]) {
            issues.append(contentsOf: callsIssue)
        }

        if normalizedIntent == "action" {
            let hasSingleActionName = strictStringValue(for: "name", in: payload) != nil
            let hasCalls = payload["calls"] != nil && validatePlannerResponseCallsPayload(payload["calls"]) == nil
            if !hasSingleActionName && !hasCalls {
                issues.append("action payload requires name or calls")
            }
        }

        return issues
    }

    private static func validatePlannerResponseCallsPayload(
        _ callsValue: PaceMCPJSONValue?
    ) -> [String]? {
        guard let callsValue else { return nil }
        guard case .array(let calls) = callsValue else {
            return ["payload.calls must be an array"]
        }

        var issues: [String] = []
        let allowedCallKeys = Set(["name", "args"])
        for (index, callValue) in calls.enumerated() {
            guard case .object(let callObject) = callValue else {
                issues.append("payload.calls[\(index)] must be an object")
                continue
            }

            for unexpectedKey in Set(callObject.keys).subtracting(allowedCallKeys).sorted() {
                issues.append("payload.calls[\(index)] unexpected key \(unexpectedKey)")
            }

            if strictStringValue(for: "name", in: callObject) == nil {
                issues.append("payload.calls[\(index)].name must be a string")
            }
            if callObject["args"] != nil && objectValue(for: "args", in: callObject) == nil {
                issues.append("payload.calls[\(index)].args must be an object")
            }
        }

        return issues.isEmpty ? nil : issues
    }

    private static func parsePlannerActions(
        intent normalizedIntent: String?,
        payload: [String: PaceMCPJSONValue]
    ) -> [PaceParsedAction]? {
        switch normalizedIntent {
        case "action":
            if let calls = actionCallObjects(from: payload) {
                return calls.compactMap(parsePlannerActionCall)
            }
            return parsePlannerActionCall(payload).map { [$0] }
        case "dictate":
            let dictatedText = firstStringValue(for: ["text", "body", "value"], in: payload)
            guard let dictatedText, !dictatedText.isEmpty else { return [] }
            let processedDictatedText = PaceDictationPostProcessor.process(
                rawText: dictatedText,
                mode: firstStringValue(for: ["mode"], in: payload)
            )
            guard !processedDictatedText.isEmpty else { return [] }
            return [.type(processedDictatedText)]
        case "edit":
            let replacementText = firstStringValue(for: ["replacement", "text", "value"], in: payload)
            if let replacementText, !replacementText.isEmpty {
                let target = parseSetTextValueTarget(
                    firstStringValue(for: ["target"], in: payload)
                ) ?? .selection
                return [.setTextValue(PaceSetTextValueRequest(
                    value: replacementText,
                    target: target
                ))]
            }

            if let editCommand = firstStringValue(for: ["command", "instruction", "operation"], in: payload),
               let voiceEditRequest = PaceVoiceEditProcessor.parseCommand(editCommand) {
                return [.editSelectedText(voiceEditRequest)]
            }

            return []
        default:
            return []
        }
    }

    private static func parsePlannerActionCall(_ actionCall: [String: PaceMCPJSONValue]) -> PaceParsedAction? {
        guard let actionName = stringValue(for: "name", in: actionCall) else { return nil }
        let actionArguments = objectValue(for: "args", in: actionCall) ?? [:]
        let validationIssues = validateParameterizedActionCall(name: actionName, arguments: actionArguments)
        guard validationIssues.isEmpty else {
            print("⚠️ Rejected invalid \(actionName) planner action before execution: \(validationIssues.joined(separator: "; "))")
            return nil
        }
        return parseParameterizedAction(name: actionName, arguments: actionArguments)
    }

    private static func actionCallObjects(from payload: [String: PaceMCPJSONValue]) -> [[String: PaceMCPJSONValue]]? {
        guard case .array(let callsValue)? = payload["calls"] else { return nil }
        return callsValue.compactMap { callValue in
            guard case .object(let callObject) = callValue else { return nil }
            return callObject
        }
    }

    private static func parseParameterizedAction(
        name rawActionName: String,
        arguments: [String: PaceMCPJSONValue]
    ) -> PaceParsedAction? {
        let normalizedActionName = normalizedParameterizedActionName(rawActionName)

        switch normalizedActionName {
        case "app.launch", "app.open", "open.app":
            let applicationName = firstStringValue(for: ["name", "app"], in: arguments)
            return applicationName.map { .openApplication($0) }
        case "app.openurl", "open.url", "url.open":
            let urlString = firstStringValue(for: ["url", "text"], in: arguments)
            return urlString.map { .openURL($0) }
        case "ax.press", "click", "mouse.click":
            if let clickCandidateSet = parseClickCandidateSet(fromParameterizedArguments: arguments, clickCount: 1) {
                return .clickCandidates(clickCandidateSet)
            }
            if let location = screenshotPixelLocation(from: arguments) {
                return .click(location)
            }
            return nil
        case "ax.doublepress", "double.click", "mouse.doubleclick":
            if let clickCandidateSet = parseClickCandidateSet(fromParameterizedArguments: arguments, clickCount: 2) {
                return .clickCandidates(clickCandidateSet)
            }
            if let location = screenshotPixelLocation(from: arguments) {
                return .doubleClick(location)
            }
            return nil
        case "ax.setvalue":
            let value = firstStringValue(for: ["value", "text", "body"], in: arguments)
            guard let value, !value.isEmpty else { return nil }
            let target = parseSetTextValueTarget(
                firstStringValue(for: ["target"], in: arguments)
            ) ?? .focused
            return .setTextValue(PaceSetTextValueRequest(
                value: value,
                target: target
            ))
        case "type", "keyboard.type":
            let text = firstStringValue(for: ["value", "text", "body"], in: arguments)
            guard let text, !text.isEmpty else { return nil }
            return .type(text)
        case "undo.last", "undo", "undo.lastmutation":
            return .undoLastMutation
        case "key.press", "keyboard.press":
            let key = firstStringValue(for: ["key", "name", "command"], in: arguments) ?? ""
            return parseKeyPayload(key)
        case "clipboard.read", "clipboard":
            return .readClipboard
        case "window.snap", "window.move", "window.resize":
            return parseWindowSnapRequest(from: arguments)
                .map { .snapWindow($0) }
        case "ax.scroll":
            let direction = stringValue(for: "direction", in: arguments) ?? "down"
            let amount = intValue(for: "amount", in: arguments)
                ?? intValue(for: "steps", in: arguments)
                ?? 3
            return parseScrollPayload("\(direction):\(amount)")
        case "music.control", "music":
            let command = firstStringValue(for: ["command", "name"], in: arguments) ?? ""
            return parseMusicPayload(command)
        case "volume.adjust", "volume":
            return parseSystemAdjustmentPayloadFromParameterizedArguments(arguments)
                .map { .adjustVolume($0) }
        case "brightness.adjust", "brightness":
            return parseSystemAdjustmentPayloadFromParameterizedArguments(arguments)
                .map { .adjustBrightness($0) }
        case "calendar.read", "calendar.list":
            let range = firstStringValue(for: ["range", "when"], in: arguments) ?? "today"
            return parseCalendarPayload(range)
        case "calendar.createevent", "calendar.create", "calendar.add", "cal.event":
            return parseCalendarEventRequest(from: arguments)
                .map { .createCalendarEvent($0) }
        case "reminders.add", "reminder.add":
            let title = firstStringValue(for: ["title", "text", "name"], in: arguments)
            guard let title, !title.isEmpty else { return nil }
            return .createReminder(PaceReminderRequest(
                title: title,
                notes: stringValue(for: "notes", in: arguments)
            ))
        case "notes.create", "note.create":
            let title = firstStringValue(for: ["title", "name"], in: arguments) ?? "Pace note"
            let body = firstStringValue(for: ["body", "text", "notes"], in: arguments) ?? ""
            guard !title.isEmpty || !body.isEmpty else { return nil }
            return .createNote(PaceNoteRequest(
                title: title.isEmpty ? "Pace note" : title,
                body: body
            ))
        case "notes.append", "note.append":
            let title = firstStringValue(for: ["title", "name"], in: arguments) ?? "Pace note"
            let body = firstStringValue(for: ["body", "text", "notes"], in: arguments) ?? ""
            guard !title.isEmpty || !body.isEmpty else { return nil }
            return .appendNote(PaceNoteRequest(
                title: title.isEmpty ? "Pace note" : title,
                body: body
            ))
        case "notes.search", "note.search":
            let query = firstStringValue(for: ["query", "text", "title", "name"], in: arguments)
            guard let query, !query.isEmpty else { return nil }
            return .searchNotes(query)
        case "mail.draft", "mail.compose":
            let recipients = stringArrayValue(for: "to", in: arguments)
                + stringArrayValue(for: "recipients", in: arguments)
                + stringArrayValue(for: "recipient", in: arguments)
            let subject = firstStringValue(for: ["subject", "title"], in: arguments) ?? ""
            let body = firstStringValue(for: ["body", "text", "bodyText"], in: arguments) ?? ""
            guard !recipients.isEmpty || !subject.isEmpty || !body.isEmpty else { return nil }
            return .composeMail(PaceMailDraft(
                recipients: recipients,
                subject: subject.isEmpty ? "Untitled" : subject,
                body: body
            ))
        case "shortcut.run", "shortcuts.run":
            let shortcutName = firstStringValue(for: ["name", "title", "shortcut"], in: arguments)
            return shortcutName.map { .runShortcut($0) }
        case "things.create", "things.add":
            let title = firstStringValue(for: ["title", "text", "name"], in: arguments)
            guard let title, !title.isEmpty else { return nil }
            return .createThingsToDo(PaceThingsToDoRequest(
                title: title,
                notes: stringValue(for: "notes", in: arguments)
            ))
        case "messages.open", "messages.draft":
            let recipient = firstStringValue(for: ["recipient", "to", "name"], in: arguments)
            let text = firstStringValue(for: ["text", "body"], in: arguments)
            return .openMessages(PaceMessageRequest(
                recipient: recipient,
                text: text
            ))
        case "mcp.call", "mcp":
            let serverName = firstStringValue(for: ["server", "serverName"], in: arguments)
            let toolName = firstStringValue(for: ["tool", "toolName", "name"], in: arguments)
            guard let serverName, !serverName.isEmpty,
                  let toolName, !toolName.isEmpty else { return nil }
            let mcpArguments = objectValue(for: "arguments", in: arguments) ?? arguments
            return .mcp(PaceMCPToolCall(
                serverName: serverName,
                toolName: toolName,
                arguments: mcpArguments
            ))
        case "file.download", "download.file":
            let rawURLString = firstStringValue(for: ["url", "text"], in: arguments) ?? ""
            guard let downloadURL = PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) else {
                return nil
            }
            let suggestedFilename = firstStringValue(for: ["filename", "name", "title"], in: arguments)
            return .downloadFile(PaceFileDownloadRequest(
                url: downloadURL,
                suggestedFilename: suggestedFilename
            ))
        case "finder.reveal":
            let path = firstStringValue(for: ["path", "url"], in: arguments)
            guard let path, !path.isEmpty else { return nil }
            return .finder(PaceFinderRequest(path: path, action: .reveal))
        case "finder.open":
            let path = firstStringValue(for: ["path", "url"], in: arguments)
            guard let path, !path.isEmpty else { return nil }
            return .finder(PaceFinderRequest(path: path, action: .open))
        case "draw.annotation", "annotate", "draw":
            return parseDrawAnnotationRequest(from: arguments)
                .map { .drawAnnotation($0) }
        case "clear.annotations", "clear.drawing", "wipe.annotations", "draw.clear":
            return .clearAnnotations
        default:
            return nil
        }
    }

    private static func validateParameterizedActionCall(
        name rawActionName: String,
        arguments: [String: PaceMCPJSONValue]
    ) -> [String] {
        let normalizedActionName = normalizedParameterizedActionName(rawActionName)
        var issues: [String] = []

        switch normalizedActionName {
        case "app.launch", "app.open", "open.app":
            if !hasNonEmptyString(for: ["name", "app"], in: arguments) {
                issues.append("requires app name")
            }
        case "app.openurl", "open.url", "url.open":
            if !hasNonEmptyString(for: ["url", "text"], in: arguments) {
                issues.append("requires url")
            }
        case "ax.press", "click", "mouse.click",
             "ax.doublepress", "double.click", "mouse.doubleclick":
            if screenshotPixelLocation(from: arguments) == nil
                && parseClickCandidateSet(fromParameterizedArguments: arguments, clickCount: 1) == nil {
                issues.append("requires x/y coordinates or candidates")
            }
        case "ax.setvalue", "type", "keyboard.type":
            if !hasNonEmptyString(for: ["value", "text", "body"], in: arguments) {
                issues.append("requires non-empty text")
            }
        case "undo.last", "undo", "undo.lastmutation", "clipboard.read", "clipboard":
            break
        case "key.press", "keyboard.press":
            let key = firstStringValue(for: ["key", "name", "command"], in: arguments) ?? ""
            if parseKeyPayload(key) == nil {
                issues.append("requires supported key")
            }
        case "window.snap", "window.move", "window.resize":
            if parseWindowSnapRequest(from: arguments) == nil {
                issues.append("requires supported window snap position")
            }
        case "ax.scroll":
            if let direction = stringValue(for: "direction", in: arguments),
               !["up", "down"].contains(direction.lowercased()) {
                issues.append("direction must be up or down")
            }
        case "music.control", "music":
            let command = firstStringValue(for: ["command", "name"], in: arguments) ?? ""
            if parseMusicPayload(command) == nil {
                issues.append("requires supported music command")
            }
        case "volume.adjust", "volume", "brightness.adjust", "brightness":
            if parseSystemAdjustmentPayloadFromParameterizedArguments(arguments) == nil {
                issues.append("requires supported adjustment direction")
            }
        case "calendar.read", "calendar.list":
            let range = firstStringValue(for: ["range", "when"], in: arguments) ?? "today"
            if parseCalendarPayload(range) == nil {
                issues.append("requires supported calendar range")
            }
        case "calendar.createevent", "calendar.create", "calendar.add", "cal.event":
            if parseCalendarEventRequest(from: arguments) == nil {
                issues.append("requires title and start date")
            }
        case "reminders.add", "reminder.add":
            if !hasNonEmptyString(for: ["title", "text", "name"], in: arguments) {
                issues.append("requires reminder title")
            }
        case "notes.create", "note.create", "notes.append", "note.append":
            if !hasNonEmptyString(for: ["title", "name", "body", "text", "notes"], in: arguments) {
                issues.append("requires note title or body")
            }
        case "notes.search", "note.search":
            if !hasNonEmptyString(for: ["query", "text", "title", "name"], in: arguments) {
                issues.append("requires notes query")
            }
        case "file.download", "download.file":
            let rawURLString = firstStringValue(for: ["url", "text"], in: arguments) ?? ""
            if PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) == nil {
                issues.append("requires a valid http(s) download url")
            }
        case "mail.draft", "mail.compose":
            if stringArrayValue(for: "to", in: arguments).isEmpty
                && stringArrayValue(for: "recipients", in: arguments).isEmpty
                && stringArrayValue(for: "recipient", in: arguments).isEmpty
                && !hasNonEmptyString(for: ["subject", "title", "body", "text", "bodyText"], in: arguments) {
                issues.append("requires recipient, subject, or body")
            }
        case "shortcut.run", "shortcuts.run":
            if !hasNonEmptyString(for: ["name", "title", "shortcut"], in: arguments) {
                issues.append("requires shortcut name")
            }
        case "things.create", "things.add":
            if !hasNonEmptyString(for: ["title", "text", "name"], in: arguments) {
                issues.append("requires todo title")
            }
        case "messages.open", "messages.draft":
            break
        case "mcp.call", "mcp":
            if !hasNonEmptyString(for: ["server", "serverName"], in: arguments) {
                issues.append("requires MCP server")
            }
            if !hasNonEmptyString(for: ["tool", "toolName", "name"], in: arguments) {
                issues.append("requires MCP tool name")
            }
        case "finder.reveal", "finder.open":
            if !hasNonEmptyString(for: ["path", "url"], in: arguments) {
                issues.append("requires path")
            }
        case "draw.annotation", "annotate", "draw":
            if parseDrawAnnotationRequest(from: arguments) == nil {
                issues.append("requires at least one valid shape")
            }
        case "clear.annotations", "clear.drawing", "wipe.annotations", "draw.clear":
            break
        default:
            issues.append("unknown action")
        }

        return issues
    }

    private static func normalizedParameterizedActionName(_ rawActionName: String) -> String {
        rawActionName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
    }

    private static func screenshotPixelLocation(from arguments: [String: PaceMCPJSONValue]) -> ScreenshotPixelLocation? {
        guard let xPixel = intValue(for: "x", in: arguments),
              let yPixel = intValue(for: "y", in: arguments) else {
            return nil
        }
        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: intValue(for: "screen", in: arguments)
        )
    }

    private static func parseClickCandidateSet(
        fromParameterizedArguments arguments: [String: PaceMCPJSONValue],
        clickCount: Int
    ) -> PaceClickCandidateSet? {
        guard case .array(let rawCandidateValues)? = arguments["candidates"] else { return nil }
        let defaultScreenNumber = intValue(for: "screen", in: arguments)
        let defaultExpectStateChange = boolValue(for: "expectStateChange", in: arguments) ?? true

        let candidates = rawCandidateValues.compactMap { rawCandidateValue -> PaceClickCandidate? in
            guard case .object(let candidateObject) = rawCandidateValue else { return nil }
            let trimmedLabel = firstStringValue(for: ["label", "title", "name"], in: candidateObject)
            let candidateLocation: ScreenshotPixelLocation? = {
                guard let xPixel = intValue(for: "x", in: candidateObject),
                      let yPixel = intValue(for: "y", in: candidateObject) else {
                    return nil
                }
                return ScreenshotPixelLocation(
                    xInScreenshotPixels: xPixel,
                    yInScreenshotPixels: yPixel,
                    screenNumber: intValue(for: "screen", in: candidateObject) ?? defaultScreenNumber
                )
            }()

            guard candidateLocation != nil || !(trimmedLabel ?? "").isEmpty else { return nil }

            return PaceClickCandidate(
                location: candidateLocation,
                label: trimmedLabel,
                confidence: max(0, min(doubleValue(for: "confidence", in: candidateObject) ?? 0.5, 1)),
                expectStateChange: boolValue(for: "expectStateChange", in: candidateObject) ?? defaultExpectStateChange,
                recency: parseClickCandidateRecency(fromParameterizedArguments: candidateObject)
            )
        }

        guard !candidates.isEmpty else { return nil }
        return PaceClickCandidateSet(candidates: candidates, clickCount: clickCount)
    }

    private static func parseClickCandidateRecency(
        fromParameterizedArguments arguments: [String: PaceMCPJSONValue]
    ) -> PaceClickCandidateRecency? {
        let rank = intValue(for: "recencyRank", in: arguments)
            ?? intValue(for: "recentRank", in: arguments)
        let lastSeenMillisecondsAgo = doubleValue(for: "lastSeenMillisecondsAgo", in: arguments)
            ?? doubleValue(for: "lastSeenMsAgo", in: arguments)
            ?? doubleValue(for: "observedMillisecondsAgo", in: arguments)
            ?? doubleValue(for: "observedMsAgo", in: arguments)
        guard rank != nil || lastSeenMillisecondsAgo != nil else { return nil }
        return PaceClickCandidateRecency(
            rank: rank,
            lastSeenMillisecondsAgo: lastSeenMillisecondsAgo
        )
    }

    private static func parseSystemAdjustmentPayloadFromParameterizedArguments(
        _ arguments: [String: PaceMCPJSONValue]
    ) -> PaceSystemAdjustment? {
        let direction = firstStringValue(for: ["direction", "command"], in: arguments) ?? "up"
        let steps = intValue(for: "steps", in: arguments)
            ?? intValue(for: "amount", in: arguments)
            ?? 2
        return parseSystemAdjustmentPayload("\(direction):\(steps)")
    }

    private static func firstStringValue(
        for keys: [String],
        in object: [String: PaceMCPJSONValue]
    ) -> String? {
        for key in keys {
            if let value = stringValue(for: key, in: object), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> String? {
        guard let value = object[key] else { return nil }
        switch value {
        case .string(let stringValue):
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let numberValue):
            if numberValue.rounded() == numberValue {
                return String(Int(numberValue))
            }
            return String(numberValue)
        case .bool(let boolValue):
            return String(boolValue)
        case .array, .object, .null:
            return nil
        }
    }

    private static func strictStringValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> String? {
        guard case .string(let stringValue)? = object[key] else { return nil }
        return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> Int? {
        guard let value = object[key] else { return nil }
        switch value {
        case .number(let numberValue):
            return Int(numberValue)
        case .string(let stringValue):
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .array, .object, .null:
            return nil
        }
    }

    private static func doubleValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> Double? {
        guard let value = object[key] else { return nil }
        switch value {
        case .number(let numberValue):
            return numberValue
        case .string(let stringValue):
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .array, .object, .null:
            return nil
        }
    }

    private static func objectValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> [String: PaceMCPJSONValue]? {
        guard case .object(let objectValue)? = object[key] else { return nil }
        return objectValue
    }

    private static func boolValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> Bool? {
        guard let value = object[key] else { return nil }
        switch value {
        case .bool(let boolValue):
            return boolValue
        case .string(let stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        case .number(let numberValue):
            return numberValue != 0
        case .array, .object, .null:
            return nil
        }
    }

    private static func stringArrayValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> [String] {
        guard let value = object[key] else { return [] }
        switch value {
        case .string(let stringValue):
            return stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .array(let arrayValue):
            return arrayValue.compactMap { element in
                switch element {
                case .string(let stringValue):
                    let trimmedString = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmedString.isEmpty ? nil : trimmedString
                case .number(let numberValue):
                    if numberValue.rounded() == numberValue {
                        return String(Int(numberValue))
                    }
                    return String(numberValue)
                case .bool, .array, .object, .null:
                    return nil
                }
            }
        case .number(let numberValue):
            if numberValue.rounded() == numberValue {
                return [String(Int(numberValue))]
            }
            return [String(numberValue)]
        case .bool, .object, .null:
            return []
        }
    }

    private static func parseSingleAction(tagName: String, payload: String) -> PaceParsedAction? {
        switch tagName {
        case "CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .click($0) }
        case "DOUBLE_CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .doubleClick($0) }
        case "TYPE":
            // TYPE payload is free text — pass through verbatim.
            return .type(payload)
        case "KEY":
            return parseKeyPayload(payload)
        case "SCROLL":
            return parseScrollPayload(payload)
        case "OPEN_APP":
            return parseOpenApplicationPayload(payload)
        case "OPEN_URL":
            return parseOpenURLPayload(payload)
        case "MUSIC":
            return parseMusicPayload(payload)
        case "VOLUME":
            return parseSystemAdjustmentPayload(payload).map { .adjustVolume($0) }
        case "BRIGHTNESS":
            return parseSystemAdjustmentPayload(payload).map { .adjustBrightness($0) }
        case "CALENDAR":
            return parseCalendarPayload(payload)
        case "REMINDER":
            return parseReminderPayload(payload)
        default:
            return nil
        }
    }

    private static func parseToolCallBlocks(in responseText: String) -> [ToolCallBlockParseResult] {
        let pattern = #"<tool_calls>(.*?)</tool_calls>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let entireRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, options: [], range: entireRange)
        guard !matches.isEmpty else { return [] }

        var parsedBlocks: [ToolCallBlockParseResult] = []

        for match in matches {
            guard let blockRange = Range(match.range, in: responseText),
                  let jsonRange = Range(match.range(at: 1), in: responseText) else { continue }
            let jsonText = String(responseText[jsonRange])
            let decodedSteps = decodeToolCallSteps(from: jsonText)
            parsedBlocks.append(ToolCallBlockParseResult(range: blockRange, steps: decodedSteps))
        }

        return parsedBlocks
    }

    private static func decodeToolCallSteps(from jsonText: String) -> [PaceActionExecutionStep] {
        guard let jsonData = jsonText.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()

        if let groupedToolCalls = try? decoder.decode([[ToolCallDTO]].self, from: jsonData) {
            return groupedToolCalls.compactMap { toolCallGroup in
                let parsedActions = toolCallGroup.compactMap(parseToolCall)
                guard parsedActions.count == toolCallGroup.count, !parsedActions.isEmpty else {
                    return nil
                }
                return PaceActionExecutionStep(actions: parsedActions)
            }
        }

        if let flatToolCalls = try? decoder.decode([ToolCallDTO].self, from: jsonData) {
            var parsedActions: [PaceParsedAction] = []
            parsedActions.reserveCapacity(flatToolCalls.count)
            for toolCall in flatToolCalls {
                guard let action = parseToolCall(toolCall) else {
                    return []
                }
                parsedActions.append(action)
            }
            guard !parsedActions.isEmpty else { return [] }
            return parsedActions.map { PaceActionExecutionStep(actions: [$0]) }
        }

        return []
    }

    private static func parseActionTagMatches(
        in responseText: String,
        excludingRanges excludedRanges: [Range<String.Index>]
    ) -> [NSTextCheckingResult] {
        let actionTagPattern = #"\[(CLICK|DOUBLE_CLICK|TYPE|KEY|SCROLL|OPEN_APP|OPEN_URL|MUSIC|VOLUME|BRIGHTNESS|CALENDAR|REMINDER):([^\]]+)\]"#
        guard let actionTagRegex = try? NSRegularExpression(
            pattern: actionTagPattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let entireRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = actionTagRegex.matches(in: responseText, options: [], range: entireRange)
        guard !matches.isEmpty else { return [] }

        return matches.filter { match in
            guard let matchRange = Range(match.range, in: responseText) else { return false }
            return !excludedRanges.contains { excludedRange in
                excludedRange.lowerBound <= matchRange.lowerBound
                    && matchRange.upperBound <= excludedRange.upperBound
            }
        }
    }

    private static func stripRanges(
        in text: String,
        removingRanges ranges: [Range<String.Index>]
    ) -> String {
        var strippedText = text
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            // The String.Index range was computed against `text`; safe
            // to apply to `strippedText` as long as we sort highest-
            // first (which keeps earlier indices stable as we mutate).
            strippedText.removeSubrange(range)
        }
        return strippedText
    }

    private static func parseToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        if let mcpToolCall = parseMCPToolCall(toolCall) {
            return .mcp(mcpToolCall)
        }

        guard let toolKind = PaceToolRegistry.kind(forToolName: toolCall.tool) else {
            return nil
        }

        let validationIssues = validateLocalToolCall(toolCall, kind: toolKind)
        guard validationIssues.isEmpty else {
            print("⚠️ Rejected invalid \(toolCall.tool) tool call before execution: \(validationIssues.joined(separator: "; "))")
            return nil
        }

        switch toolKind {
        case .click:
            if let clickCandidateSet = parseClickCandidateSet(toolCall, clickCount: 1) {
                return .clickCandidates(clickCandidateSet)
            }
            return parseToolCallLocation(toolCall).map { .click($0) }
        case .doubleClick:
            if let clickCandidateSet = parseClickCandidateSet(toolCall, clickCount: 2) {
                return .clickCandidates(clickCandidateSet)
            }
            return parseToolCallLocation(toolCall).map { .doubleClick($0) }
        case .type:
            guard let text = toolCall.text, !text.isEmpty else { return nil }
            return .type(text)
        case .setValue:
            let mergedArguments = mergeMCPArguments(from: toolCall)
            let value = (firstStringValue(for: ["value", "text", "body"], in: mergedArguments) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let target = parseSetTextValueTarget(firstStringValue(for: ["target", "action"], in: mergedArguments)) ?? .focused
            return .setTextValue(PaceSetTextValueRequest(
                value: value,
                target: target
            ))
        case .undo:
            return .undoLastMutation
        case .key:
            return parseKeyPayload(toolCall.key ?? toolCall.command ?? "")
        case .clipboard:
            return .readClipboard
        case .window:
            return parseWindowToolCall(toolCall)
        case .scroll:
            return parseScrollPayload(
                [
                    toolCall.direction,
                    (toolCall.amount ?? toolCall.steps).map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            )
        case .openApp:
            return parseOpenApplicationPayload(toolCall.app ?? toolCall.name ?? "")
        case .openURL:
            return parseOpenURLPayload(toolCall.url ?? toolCall.text ?? "")
        case .music:
            return parseMusicPayload(toolCall.command ?? "")
        case .volume:
            return parseSystemAdjustmentPayload(
                [
                    toolCall.direction,
                    toolCall.steps.map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            ).map { .adjustVolume($0) }
        case .brightness:
            return parseSystemAdjustmentPayload(
                [
                    toolCall.direction,
                    toolCall.steps.map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            ).map { .adjustBrightness($0) }
        case .calendar:
            if let calendarEventAction = parseCalendarEventToolCallIfRequested(toolCall) {
                return calendarEventAction
            }
            return parseCalendarPayload(toolCall.range ?? "today")
        case .calendarCreate:
            return parseCalendarEventToolCall(toolCall)
        case .reminder:
            return parseReminderPayload(toolCall.title ?? toolCall.text ?? "")
        case .finder:
            return parseFinderToolCall(toolCall)
        case .notes:
            return parseNoteToolCall(toolCall)
        case .mail:
            return parseMailToolCall(toolCall)
        case .things:
            return parseThingsToolCall(toolCall)
        case .shortcuts:
            return parseShortcutToolCall(toolCall)
        case .messages:
            return parseMessagesToolCall(toolCall)
        case .downloadFile:
            return parseDownloadFileToolCall(toolCall)
        case .startTimer:
            return parseStartTimerToolCall(toolCall)
        case .recordFlow:
            return parseFlowToolCall(toolCall, action: .record)
        case .runFlow:
            return parseFlowToolCall(toolCall, action: .run)
        case .drawAnnotation:
            return parseDrawAnnotationRequest(from: mergeMCPArguments(from: toolCall))
                .map { .drawAnnotation($0) }
        case .clearAnnotations:
            return .clearAnnotations
        }
    }

    private enum FlowToolAction {
        case record
        case run
    }

    private static func parseFlowToolCall(_ toolCall: ToolCallDTO, action: FlowToolAction) -> PaceParsedAction? {
        let mergedArguments = mergeMCPArguments(from: toolCall)
        guard let rawName = firstStringValue(
            for: ["name", "title", "flow", "label"],
            in: mergedArguments
        ) else {
            return nil
        }
        let request = PaceFlowActionRequest(name: rawName.trimmingCharacters(in: .whitespacesAndNewlines))
        switch action {
        case .record:
            return .recordFlow(request)
        case .run:
            return .runFlow(request)
        }
    }

    private static func parseStartTimerToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let mergedArguments = mergeMCPArguments(from: toolCall)
        guard let rawDurationText = firstStringValue(
            for: ["duration", "time", "for", "interval", "seconds", "minutes"],
            in: mergedArguments
        ) else {
            return nil
        }
        guard let durationInSeconds = PaceTimerDurationParser.seconds(from: rawDurationText) else {
            return nil
        }
        let rawLabel = firstStringValue(
            for: ["label", "name", "title", "reason", "text"],
            in: mergedArguments
        ) ?? ""
        let trimmedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return .startTimer(PaceTimerRequest(label: trimmedLabel, durationInSeconds: durationInSeconds))
    }

    private static func validateLocalToolCall(_ toolCall: ToolCallDTO, kind: PaceLocalToolKind) -> [String] {
        let mergedArguments = mergeMCPArguments(from: toolCall)
        var issues: [String] = []

        // Defense-in-depth for the no-destructive-tools invariant (also
        // enforced by registry startup validation): even if a destructive
        // definition slipped past startup, its calls are rejected here
        // before approval or execution.
        if PaceToolRegistry.localTools.first(where: { $0.kind == kind })?.riskLevel == .destructive {
            issues.append("destructive actions are not permitted")
        }

        switch kind {
        case .click, .doubleClick:
            if parseToolCallLocation(toolCall) == nil && parseClickCandidateSet(toolCall, clickCount: 1) == nil {
                issues.append("requires x/y coordinates or candidates")
            }
        case .type:
            if !hasNonEmptyString(for: ["text", "body", "value"], in: mergedArguments) {
                issues.append("requires non-empty text")
            }
        case .setValue:
            if !hasNonEmptyString(for: ["value", "text", "body"], in: mergedArguments) {
                issues.append("requires non-empty value")
            }
            if let target = firstStringValue(for: ["target", "action"], in: mergedArguments),
               parseSetTextValueTarget(target) == nil {
                issues.append("target must be focused or selection")
            }
        case .undo, .clipboard:
            break
        case .key:
            if !hasNonEmptyString(for: ["key", "command", "name"], in: mergedArguments) {
                issues.append("requires key")
            }
        case .window:
            if parseWindowSnapRequest(from: mergedArguments) == nil {
                issues.append("requires a supported window snap position")
            }
        case .scroll:
            if let direction = firstStringValue(for: ["direction", "command"], in: mergedArguments) {
                if !["up", "down"].contains(direction.lowercased()) {
                    issues.append("direction must be up or down")
                }
            }
        case .openApp:
            if !hasNonEmptyString(for: ["app", "name"], in: mergedArguments) {
                issues.append("requires app")
            }
        case .openURL:
            if !hasNonEmptyString(for: ["url", "text"], in: mergedArguments) {
                issues.append("requires url")
            }
        case .music:
            let command = firstStringValue(for: ["command", "name"], in: mergedArguments) ?? ""
            if parseMusicPayload(command) == nil {
                issues.append("requires supported music command")
            }
        case .volume, .brightness:
            let direction = firstStringValue(for: ["direction", "command"], in: mergedArguments)
            if let direction {
                if !["up", "down"].contains(direction.lowercased()) {
                    issues.append("direction must be up or down")
                }
            } else {
                issues.append("requires direction")
            }
        case .calendar:
            let normalizedAction = (firstStringValue(for: ["action"], in: mergedArguments) ?? "")
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            if ["create", "create_event", "add", "schedule"].contains(normalizedAction) {
                if parseCalendarEventToolCall(toolCall) == nil {
                    issues.append("requires title and start date")
                }
                break
            }
            let range = firstStringValue(for: ["range", "when"], in: mergedArguments) ?? "today"
            if parseCalendarPayload(range) == nil {
                issues.append("requires supported calendar range")
            }
        case .calendarCreate:
            if parseCalendarEventToolCall(toolCall) == nil {
                issues.append("requires title and start date")
            }
        case .reminder:
            if !hasNonEmptyString(for: ["title", "text", "name"], in: mergedArguments) {
                issues.append("requires reminder title")
            }
        case .finder:
            if !hasNonEmptyString(for: ["path", "text"], in: mergedArguments) {
                issues.append("requires path")
            }
        case .notes:
            let normalizedAction = (firstStringValue(for: ["action"], in: mergedArguments) ?? "create")
                .lowercased()
            if ["search", "find"].contains(normalizedAction) {
                if !hasNonEmptyString(for: ["query", "text", "title", "name", "body", "notes"], in: mergedArguments) {
                    issues.append("requires notes query")
                }
            } else if !hasNonEmptyString(for: ["title", "name", "body", "text", "notes"], in: mergedArguments) {
                issues.append("requires note title or body")
            }
        case .mail:
            if !hasNonEmptyString(for: ["to", "recipient", "subject", "title", "body", "text"], in: mergedArguments) {
                issues.append("requires recipient, subject, or body")
            }
        case .things:
            if !hasNonEmptyString(for: ["title", "text", "name"], in: mergedArguments) {
                issues.append("requires todo title")
            }
        case .shortcuts:
            if !hasNonEmptyString(for: ["name", "title", "command"], in: mergedArguments) {
                issues.append("requires shortcut name")
            }
        case .messages:
            break
        case .downloadFile:
            let rawURLString = firstStringValue(for: ["url", "text"], in: mergedArguments) ?? ""
            if PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) == nil {
                issues.append("requires a valid http(s) download url")
            }
        case .startTimer:
            let rawDurationText = firstStringValue(
                for: ["duration", "time", "for", "interval", "seconds", "minutes"],
                in: mergedArguments
            ) ?? ""
            if PaceTimerDurationParser.seconds(from: rawDurationText) == nil {
                issues.append("requires a valid duration (e.g. \"3 minutes\", \"30s\")")
            }
        case .recordFlow, .runFlow:
            if !hasNonEmptyString(for: ["name", "title", "flow", "label"], in: mergedArguments) {
                issues.append("requires flow name")
            }
        case .drawAnnotation:
            if parseDrawAnnotationRequest(from: mergedArguments) == nil {
                issues.append("requires at least one valid shape")
            }
        case .clearAnnotations:
            break
        }

        return issues
    }

    private static func hasNonEmptyString(
        for keys: [String],
        in object: [String: PaceMCPJSONValue]
    ) -> Bool {
        firstStringValue(for: keys, in: object) != nil
    }

    private static func parseMCPToolCall(_ toolCall: ToolCallDTO) -> PaceMCPToolCall? {
        let normalizedToolName = toolCall.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let serverName = toolCall.server?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedToolName == "mcp" {
            guard let serverName, !serverName.isEmpty else { return nil }
            let mcpToolName = [
                toolCall.toolName,
                toolCall.mcpTool,
                toolCall.name,
                toolCall.command,
                toolCall.action
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

            guard let mcpToolName else { return nil }
            var serverArguments = mergeMCPArguments(from: toolCall)
            // Top-level `name`/`action`/`command` can carry the MCP tool name
            // rather than a real tool argument — drop them when they only
            // duplicate the resolved tool name so servers get clean arguments.
            for routingKey in ["name", "action", "command"] {
                if case .string(let routingValue)? = serverArguments[routingKey],
                   routingValue == mcpToolName {
                    serverArguments.removeValue(forKey: routingKey)
                }
            }
            return PaceMCPToolCall(
                serverName: serverName,
                toolName: mcpToolName,
                arguments: serverArguments
            )
        }

        if let serverName, !serverName.isEmpty, PaceToolRegistry.kind(forToolName: toolCall.tool) == nil {
            return PaceMCPToolCall(
                serverName: serverName,
                toolName: toolCall.tool,
                arguments: mergeMCPArguments(from: toolCall)
            )
        }

        return nil
    }

    private static func mergeMCPArguments(from toolCall: ToolCallDTO) -> [String: PaceMCPJSONValue] {
        var arguments = toolCall.arguments

        let knownPayloadArguments: [(String, PaceMCPJSONValue?)] = [
            ("app", toolCall.app.map { .string($0) }),
            ("url", toolCall.url.map { .string($0) }),
            ("command", toolCall.command.map { .string($0) }),
            ("direction", toolCall.direction.map { .string($0) }),
            ("title", toolCall.title.map { .string($0) }),
            ("name", toolCall.name.map { .string($0) }),
            ("query", toolCall.query.map { .string($0) }),
            ("action", toolCall.action.map { .string($0) }),
            ("text", toolCall.text.map { .string($0) }),
            ("body", toolCall.body.map { .string($0) }),
            ("notes", toolCall.notes.map { .string($0) }),
            ("range", toolCall.range.map { .string($0) }),
            ("key", toolCall.key.map { .string($0) }),
            ("path", toolCall.path.map { .string($0) }),
            ("to", toolCall.to.map { .string($0) }),
            ("subject", toolCall.subject.map { .string($0) }),
            ("recipient", toolCall.recipient.map { .string($0) }),
            ("steps", toolCall.steps.map { .number(Double($0)) }),
            ("amount", toolCall.amount.map { .number(Double($0)) }),
            ("x", toolCall.x.map { .number(Double($0)) }),
            ("y", toolCall.y.map { .number(Double($0)) }),
            ("screen", toolCall.screen.map { .number(Double($0)) })
        ]

        for (key, value) in knownPayloadArguments {
            guard let value else { continue }
            arguments[key] = value
        }

        for (key, value) in toolCall.extraArguments {
            arguments[key] = value
        }
        return arguments
    }

    // MARK: - Tuition-mode draw_annotation parsing

    /// Parse a `draw_annotation` tool call into a `PaceAnnotationRequest`.
    /// Returns nil when `shapes` is missing, empty, or every entry fails
    /// to parse into a recognized shape. Truncates anything beyond
    /// `PaceAnnotationRequest.maximumShapeCount`.
    private static func parseDrawAnnotationRequest(
        from arguments: [String: PaceMCPJSONValue]
    ) -> PaceAnnotationRequest? {
        guard case .array(let rawShapeValues)? = arguments["shapes"],
              !rawShapeValues.isEmpty else {
            return nil
        }

        let truncatedShapeValues = Array(rawShapeValues.prefix(PaceAnnotationRequest.maximumShapeCount))
        let parsedShapes = truncatedShapeValues.compactMap(parseSingleAnnotationShape(_:))
        guard !parsedShapes.isEmpty else { return nil }

        return PaceAnnotationRequest(
            shapes: parsedShapes,
            screenNumber: intValue(for: "screen", in: arguments)
        )
    }

    /// Parse one shape entry from the `shapes` array. Returns nil when
    /// the required geometry for the requested kind is missing or
    /// invalid (e.g. polygon with <3 vertices).
    private static func parseSingleAnnotationShape(_ shapeValue: PaceMCPJSONValue) -> PaceAnnotationShape? {
        guard case .object(let shapeObject) = shapeValue else { return nil }

        let style = parseAnnotationStyle(from: shapeObject)
        let normalizedKind = (stringValue(for: "kind", in: shapeObject)
            ?? stringValue(for: "type", in: shapeObject)
            ?? "rect")
            .lowercased()

        switch normalizedKind {
        case "rect", "rectangle", "box":
            guard let xPixel = doubleValue(for: "x", in: shapeObject),
                  let yPixel = doubleValue(for: "y", in: shapeObject),
                  let widthPixels = doubleValue(for: "width", in: shapeObject),
                  let heightPixels = doubleValue(for: "height", in: shapeObject),
                  widthPixels > 0, heightPixels > 0 else { return nil }
            return .rect(x: xPixel, y: yPixel, width: widthPixels, height: heightPixels, style: style)
        case "ellipse", "circle", "oval":
            // Circle is the special case where width==height; planner can
            // pass either {kind:"circle",x,y,radius} or
            // {kind:"circle",x,y,width,height}. Normalize radius into a
            // bounding box centered on (x,y).
            if let radius = doubleValue(for: "radius", in: shapeObject),
               radius > 0,
               let centerX = doubleValue(for: "x", in: shapeObject),
               let centerY = doubleValue(for: "y", in: shapeObject) {
                return .ellipse(
                    x: centerX - radius,
                    y: centerY - radius,
                    width: radius * 2,
                    height: radius * 2,
                    style: style
                )
            }
            guard let xPixel = doubleValue(for: "x", in: shapeObject),
                  let yPixel = doubleValue(for: "y", in: shapeObject),
                  let widthPixels = doubleValue(for: "width", in: shapeObject),
                  let heightPixels = doubleValue(for: "height", in: shapeObject),
                  widthPixels > 0, heightPixels > 0 else { return nil }
            return .ellipse(x: xPixel, y: yPixel, width: widthPixels, height: heightPixels, style: style)
        case "line":
            guard let firstX = doubleValue(for: "x1", in: shapeObject),
                  let firstY = doubleValue(for: "y1", in: shapeObject),
                  let secondX = doubleValue(for: "x2", in: shapeObject),
                  let secondY = doubleValue(for: "y2", in: shapeObject) else { return nil }
            return .line(x1: firstX, y1: firstY, x2: secondX, y2: secondY, style: style)
        case "arrow":
            // The planner's x1/y1 is the tail; x2/y2 is the head (where
            // the arrowhead is drawn). Same field names as `line` to
            // keep the prompt simple.
            guard let tailX = doubleValue(for: "x1", in: shapeObject),
                  let tailY = doubleValue(for: "y1", in: shapeObject),
                  let headX = doubleValue(for: "x2", in: shapeObject),
                  let headY = doubleValue(for: "y2", in: shapeObject) else { return nil }
            return .arrow(tailX: tailX, tailY: tailY, headX: headX, headY: headY, style: style)
        case "polygon", "pentagon", "hexagon", "octagon":
            guard case .array(let rawPointValues)? = shapeObject["points"] else { return nil }
            let parsedPoints = rawPointValues.compactMap(parseAnnotationPointPair(_:))
            // Pentagon = 5 points; we accept any closed polygon with ≥3
            // vertices. Anything less isn't a polygon — degenerate
            // shapes belong on the `line` path.
            guard parsedPoints.count >= 3 else { return nil }
            return .polygon(points: parsedPoints, style: style)
        default:
            return nil
        }
    }

    /// Read one `[x, y]` pair from the polygon `points` array. Accepts
    /// either a 2-element JSON array or an object with `x`/`y` fields.
    private static func parseAnnotationPointPair(_ pointValue: PaceMCPJSONValue) -> CGPoint? {
        switch pointValue {
        case .array(let coordinateValues):
            guard coordinateValues.count >= 2,
                  case .number(let xCoordinate) = coordinateValues[0],
                  case .number(let yCoordinate) = coordinateValues[1] else { return nil }
            return CGPoint(x: xCoordinate, y: yCoordinate)
        case .object(let pointObject):
            guard let xCoordinate = doubleValue(for: "x", in: pointObject),
                  let yCoordinate = doubleValue(for: "y", in: pointObject) else { return nil }
            return CGPoint(x: xCoordinate, y: yCoordinate)
        default:
            return nil
        }
    }

    /// Pull `color`, `label`, `strokeWidth`, `filled` from a shape
    /// object. Every field is optional; defaults come from
    /// `PaceAnnotationStyle.default` and the sanitizing helpers on
    /// `PaceAnnotationStyle`.
    private static func parseAnnotationStyle(
        from shapeObject: [String: PaceMCPJSONValue]
    ) -> PaceAnnotationStyle {
        let color = PaceAnnotationColor.from(rawValue: stringValue(for: "color", in: shapeObject))
        let label = PaceAnnotationStyle.sanitizedLabel(stringValue(for: "label", in: shapeObject))
        let strokeWidth = PaceAnnotationStyle.clampedStrokeWidth(
            doubleValue(for: "strokeWidth", in: shapeObject)
                ?? doubleValue(for: "stroke_width", in: shapeObject)
                ?? doubleValue(for: "stroke", in: shapeObject)
        )
        let filled = boolValue(for: "filled", in: shapeObject)
            ?? boolValue(for: "fill", in: shapeObject)
            ?? false
        return PaceAnnotationStyle(
            color: color,
            label: label,
            strokeWidth: strokeWidth,
            filled: filled
        )
    }

    private static func parseToolCallLocation(_ toolCall: ToolCallDTO) -> ScreenshotPixelLocation? {
        guard let xPixel = toolCall.x, let yPixel = toolCall.y else { return nil }
        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: toolCall.screen
        )
    }

    private static func parseClickCandidateSet(
        _ toolCall: ToolCallDTO,
        clickCount: Int
    ) -> PaceClickCandidateSet? {
        let candidates = toolCall.candidates.compactMap { candidateDTO -> PaceClickCandidate? in
            let trimmedLabel = candidateDTO.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateLocation: ScreenshotPixelLocation? = {
                guard let xPixel = candidateDTO.x, let yPixel = candidateDTO.y else { return nil }
                return ScreenshotPixelLocation(
                    xInScreenshotPixels: xPixel,
                    yInScreenshotPixels: yPixel,
                    screenNumber: candidateDTO.screen ?? toolCall.screen
                )
            }()

            guard candidateLocation != nil || !(trimmedLabel ?? "").isEmpty else { return nil }

            return PaceClickCandidate(
                location: candidateLocation,
                label: trimmedLabel,
                confidence: max(0, min(candidateDTO.confidence ?? 0.5, 1)),
                expectStateChange: candidateDTO.expectStateChange ?? toolCall.expectStateChange ?? true,
                recency: parseClickCandidateRecency(candidateDTO)
            )
        }

        guard !candidates.isEmpty else { return nil }
        return PaceClickCandidateSet(candidates: candidates, clickCount: clickCount)
    }

    private static func parseClickCandidateRecency(
        _ candidateDTO: ToolCallDTO.ClickCandidateDTO
    ) -> PaceClickCandidateRecency? {
        guard candidateDTO.recencyRank != nil || candidateDTO.lastSeenMillisecondsAgo != nil else {
            return nil
        }
        return PaceClickCandidateRecency(
            rank: candidateDTO.recencyRank,
            lastSeenMillisecondsAgo: candidateDTO.lastSeenMillisecondsAgo
        )
    }

    private static func firstClickVisualisationLocation(in actions: [PaceParsedAction]) -> ScreenshotPixelLocation? {
        for action in actions {
            switch action {
            case .click(let location), .doubleClick(let location):
                return location
            case .clickCandidates(let clickCandidateSet):
                return clickCandidateSet.selectedFallbackLocation
            default:
                continue
            }
        }
        return nil
    }

    /// Parses `x,y` or `x,y:screenN` into a ScreenshotPixelLocation.
    private static func parseScreenshotPixelLocationPayload(_ payload: String) -> ScreenshotPixelLocation? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard let coordinateComponent = payloadComponents.first else { return nil }

        let xyComponents = coordinateComponent.split(separator: ",", omittingEmptySubsequences: false)
        guard xyComponents.count == 2,
              let xPixel = Int(xyComponents[0].trimmingCharacters(in: .whitespaces)),
              let yPixel = Int(xyComponents[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        var screenNumber: Int? = nil
        for trailingComponent in payloadComponents.dropFirst() {
            let trimmedTrailingComponent = trailingComponent.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmedTrailingComponent.hasPrefix("screen") {
                let digitsString = trimmedTrailingComponent.dropFirst("screen".count)
                screenNumber = Int(digitsString)
            }
        }

        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: screenNumber
        )
    }

    /// Parses `Return`, `cmd+s`, `cmd+shift+t` into a pressKey action.
    private static func parseKeyPayload(_ payload: String) -> PaceParsedAction? {
        let plusSeparatedTokens = payload.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let mainKeyToken = plusSeparatedTokens.last, !mainKeyToken.isEmpty else { return nil }
        // Reject key names the executor cannot map to a virtual key code, so
        // the planner gets a parse-time rejection instead of a mid-plan failure.
        guard PaceActionExecutor.virtualKeyCode(forKeyName: mainKeyToken) != nil else { return nil }

        var modifiers: [PaceKeyboardModifier] = []
        for modifierToken in plusSeparatedTokens.dropLast() {
            switch modifierToken {
            case "cmd", "command", "meta": modifiers.append(.command)
            case "opt", "option", "alt": modifiers.append(.option)
            case "ctrl", "control": modifiers.append(.control)
            case "shift": modifiers.append(.shift)
            default: continue
            }
        }

        return .pressKey(name: mainKeyToken, modifiers: modifiers)
    }

    /// Parses `up:3` / `down:5` into a scroll action.
    private static func parseScrollPayload(_ payload: String) -> PaceParsedAction? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: true)
        guard let directionString = payloadComponents.first,
              let direction = PaceScrollDirection(rawValue: directionString.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }

        let amountInLines: Int = {
            if payloadComponents.count >= 2,
               let parsedAmount = Int(payloadComponents[1].trimmingCharacters(in: .whitespaces)) {
                return max(1, min(parsedAmount, 50)) // clamp to a reasonable range
            }
            return 3
        }()

        return .scroll(direction, amountInLines: amountInLines)
    }

    private static func parseOpenApplicationPayload(_ payload: String) -> PaceParsedAction? {
        let applicationName = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !applicationName.isEmpty else { return nil }
        return .openApplication(applicationName)
    }

    private static func parseOpenURLPayload(_ payload: String) -> PaceParsedAction? {
        let urlString = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return nil }
        return .openURL(urlString)
    }

    private static func parseSetTextValueTarget(_ rawTarget: String?) -> PaceSetTextValueTarget? {
        let normalizedTarget = rawTarget?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch normalizedTarget {
        case "focused", "focus", "field", "value":
            return .focused
        case "selection", "selected", "selected_text", "replace_selection":
            return .selection
        default:
            return nil
        }
    }

    private static func parseWindowSnapRequest(
        from arguments: [String: PaceMCPJSONValue]
    ) -> PaceWindowSnapRequest? {
        let rawPosition = firstStringValue(
            for: ["position", "target", "side", "direction", "action"],
            in: arguments
        )
        guard let position = parseWindowSnapPosition(rawPosition) else {
            return nil
        }
        return PaceWindowSnapRequest(position: position)
    }

    private static func parseWindowSnapPosition(_ rawPosition: String?) -> PaceWindowSnapPosition? {
        let normalizedPosition = rawPosition?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalizedPosition {
        case "left", "left_half", "left_side":
            return .left
        case "right", "right_half", "right_side":
            return .right
        case "top", "top_half", "upper_half":
            return .top
        case "bottom", "bottom_half", "lower_half":
            return .bottom
        case "maximize", "maximise", "full", "fullscreen", "full_screen":
            return .maximize
        case "center", "centre", "middle":
            return .center
        default:
            return nil
        }
    }

    private static func parseMusicPayload(_ payload: String) -> PaceParsedAction? {
        let normalizedCommand = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalizedCommand {
        case "play":
            return .controlMusic(.play)
        case "pause":
            return .controlMusic(.pause)
        case "play_pause", "playpause", "toggle":
            return .controlMusic(.playPause)
        case "next", "next_track":
            return .controlMusic(.next)
        case "previous", "prev", "previous_track":
            return .controlMusic(.previous)
        default:
            return nil
        }
    }

    private static func parseCalendarPayload(_ payload: String) -> PaceParsedAction? {
        let normalizedRange = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let range: PaceCalendarRange
        switch normalizedRange {
        case "today", "":
            range = .today
        case "tomorrow":
            range = .tomorrow
        case "week", "next_week", "next_7_days", "next 7 days":
            range = .week
        default:
            return nil
        }
        return .listCalendarEvents(PaceCalendarQuery(range: range))
    }

    private struct ParsedCalendarDate {
        let date: Date
        let isDateOnly: Bool
    }

    private static func parseCalendarEventRequest(
        from arguments: [String: PaceMCPJSONValue]
    ) -> PaceCalendarEventRequest? {
        let title = firstStringValue(for: ["title", "name", "summary"], in: arguments) ?? ""
        guard !title.isEmpty else { return nil }

        let rawStartDate = firstStringValue(
            for: ["start", "startDate", "startsAt", "date", "when"],
            in: arguments
        )
        guard let rawStartDate,
              let parsedStartDate = parseCalendarDate(rawStartDate) else {
            return nil
        }

        let rawEndDate = firstStringValue(for: ["end", "endDate", "endsAt"], in: arguments)
        let parsedEndDate = rawEndDate.flatMap(parseCalendarDate)
        let isAllDay = boolValue(for: "allDay", in: arguments)
            ?? boolValue(for: "isAllDay", in: arguments)
            ?? parsedStartDate.isDateOnly

        let defaultEndDate: Date = {
            let calendar = Calendar.current
            if isAllDay {
                return calendar.date(byAdding: .day, value: 1, to: parsedStartDate.date)
                    ?? parsedStartDate.date.addingTimeInterval(24 * 60 * 60)
            }
            return calendar.date(byAdding: .hour, value: 1, to: parsedStartDate.date)
                ?? parsedStartDate.date.addingTimeInterval(60 * 60)
        }()

        let endDate = parsedEndDate?.date ?? defaultEndDate
        let safeEndDate = endDate > parsedStartDate.date ? endDate : defaultEndDate

        return PaceCalendarEventRequest(
            title: title,
            startDate: parsedStartDate.date,
            endDate: safeEndDate,
            isAllDay: isAllDay,
            notes: firstStringValue(for: ["notes", "body", "description"], in: arguments),
            location: firstStringValue(for: ["location", "place"], in: arguments),
            calendarTitle: firstStringValue(for: ["calendar", "calendarTitle"], in: arguments)
        )
    }

    private static func parseCalendarDate(_ rawDate: String) -> ParsedCalendarDate? {
        let trimmedRawDate = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawDate.isEmpty else { return nil }

        if let dateOnlyDate = parseDateOnly(trimmedRawDate) {
            return ParsedCalendarDate(date: dateOnlyDate, isDateOnly: true)
        }

        let iso8601FormatterWithFractionalSeconds = ISO8601DateFormatter()
        iso8601FormatterWithFractionalSeconds.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = iso8601FormatterWithFractionalSeconds.date(from: trimmedRawDate) {
            return ParsedCalendarDate(date: date, isDateOnly: false)
        }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime]
        if let date = iso8601Formatter.date(from: trimmedRawDate) {
            return ParsedCalendarDate(date: date, isDateOnly: false)
        }

        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd h:mm a"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmedRawDate) {
                return ParsedCalendarDate(date: date, isDateOnly: false)
            }
        }

        return nil
    }

    private static func parseDateOnly(_ rawDate: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: rawDate).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func parseReminderPayload(_ payload: String) -> PaceParsedAction? {
        let reminderTitle = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reminderTitle.isEmpty else { return nil }
        return .createReminder(PaceReminderRequest(title: reminderTitle, notes: nil))
    }

    private static func parseCalendarEventToolCallIfRequested(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let normalizedAction = (toolCall.action ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        guard ["create", "create_event", "add", "schedule"].contains(normalizedAction) else {
            return nil
        }

        return parseCalendarEventToolCall(toolCall)
    }

    private static func parseCalendarEventToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        parseParameterizedAction(
            name: "Calendar.createEvent",
            arguments: mergeMCPArguments(from: toolCall)
        )
    }

    private static func parseWindowToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        parseParameterizedAction(
            name: "Window.snap",
            arguments: mergeMCPArguments(from: toolCall)
        )
    }

    private static func parseFinderToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let path = (toolCall.path ?? toolCall.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let normalizedAction = (toolCall.action ?? "open")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let finderAction: PaceFinderAction = normalizedAction == "reveal" ? .reveal : .open

        return .finder(PaceFinderRequest(path: path, action: finderAction))
    }

    private static func parseNoteToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let normalizedAction = (toolCall.action ?? "create")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let title = (toolCall.title ?? toolCall.name ?? "Pace note")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (toolCall.body ?? toolCall.text ?? toolCall.notes ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedAction == "search" || normalizedAction == "find" {
            let query = (toolCall.query ?? toolCall.text ?? toolCall.title ?? toolCall.name ?? body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return nil }
            return .searchNotes(query)
        }

        guard !title.isEmpty || !body.isEmpty else { return nil }
        let noteRequest = PaceNoteRequest(
            title: title.isEmpty ? "Pace note" : title,
            body: body
        )

        if normalizedAction == "append" || normalizedAction == "add" || normalizedAction == "update" {
            return .appendNote(noteRequest)
        }

        return .createNote(noteRequest)
    }

    private static func parseDownloadFileToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let rawURLString = toolCall.url ?? toolCall.text ?? ""
        guard let downloadURL = PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) else {
            return nil
        }
        let suggestedFilename = (toolCall.name ?? toolCall.title)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .downloadFile(PaceFileDownloadRequest(
            url: downloadURL,
            suggestedFilename: suggestedFilename?.isEmpty == false ? suggestedFilename : nil
        ))
    }

    private static func parseMailToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let recipients = (toolCall.to ?? toolCall.recipient ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let subject = (toolCall.subject ?? toolCall.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (toolCall.body ?? toolCall.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty || !body.isEmpty || !recipients.isEmpty else { return nil }

        return .composeMail(PaceMailDraft(
            recipients: recipients,
            subject: subject.isEmpty ? "Untitled" : subject,
            body: body
        ))
    }

    private static func parseThingsToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let title = (toolCall.title ?? toolCall.text ?? toolCall.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return .createThingsToDo(PaceThingsToDoRequest(title: title, notes: toolCall.notes))
    }

    private static func parseShortcutToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let shortcutName = (toolCall.name ?? toolCall.title ?? toolCall.command ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutName.isEmpty else { return nil }
        return .runShortcut(shortcutName)
    }

    private static func parseMessagesToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let recipient = (toolCall.recipient ?? toolCall.to ?? toolCall.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (toolCall.text ?? toolCall.body)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .openMessages(PaceMessageRequest(
            recipient: recipient?.isEmpty == false ? recipient : nil,
            text: text?.isEmpty == false ? text : nil
        ))
    }

    /// Parses `up`, `down`, `up:3`, `down:5` into a relative system adjustment.
    private static func parseSystemAdjustmentPayload(_ payload: String) -> PaceSystemAdjustment? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: true)
        guard let directionString = payloadComponents.first,
              let direction = PaceAdjustmentDirection(rawValue: directionString.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }

        let stepCount: Int = {
            if payloadComponents.count >= 2,
               let parsedStepCount = Int(payloadComponents[1].trimmingCharacters(in: .whitespaces)) {
                return max(1, min(parsedStepCount, 10))
            }
            return 2
        }()

        return PaceSystemAdjustment(direction: direction, stepCount: stepCount)
    }
}
