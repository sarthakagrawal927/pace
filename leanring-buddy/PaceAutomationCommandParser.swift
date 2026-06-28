//
//  PaceAutomationCommandParser.swift
//  leanring-buddy
//
//  Pre-planner voice command parsers for the automation features:
//  cron scheduling, background agents, meeting mode, and skills.
//  Each parser follows the existing pattern (PaceWatchModeCommandParser,
//  PaceRecipeCommandParser, etc.) — deterministic, no model, no screen.
//

import Foundation

// MARK: - Cron scheduling

enum PaceCronCommand {
    case add(prompt: String, displayName: String)
    case list
    case remove(displayName: String)
    case enable
    case disable
}

nonisolated enum PaceCronCommandParser {
    static func parse(_ transcript: String) -> PaceCronCommand? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "list my scheduled tasks" / "list cron tasks" / "what are my recurring tasks"
        if lower.contains("list") && (lower.contains("recurring") || lower.contains("scheduled task") || lower.contains("cron")) {
            return .list
        }

        // "stop all recurring tasks" / "disable cron" / "disable scheduling"
        if (lower.contains("stop") || lower.contains("disable")) && (lower.contains("recurring") || lower.contains("cron") || lower.contains("scheduling")) {
            return .disable
        }

        // "enable cron" / "enable scheduling"
        if (lower.contains("enable") || lower.contains("start")) && (lower.contains("cron") || lower.contains("scheduling")) && !lower.contains("every") {
            return .enable
        }

        // "remove the <name> task" / "cancel the <name> recurring task"
        if (lower.hasPrefix("remove ") || lower.hasPrefix("cancel ")) && lower.contains("task") {
            let name = lower
                .replacingOccurrences(of: "remove the ", with: "")
                .replacingOccurrences(of: "remove ", with: "")
                .replacingOccurrences(of: "cancel the ", with: "")
                .replacingOccurrences(of: "cancel ", with: "")
                .replacingOccurrences(of: " recurring task", with: "")
                .replacingOccurrences(of: " task", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return .remove(displayName: name)
            }
        }

        // "every 30 minutes check my calendar" — delegate to PaceCronScheduler
        if lower.hasPrefix("every ") {
            if let task = PaceCronScheduler.parseVoiceCommand(transcript) {
                return .add(prompt: task.taskPrompt, displayName: task.displayName)
            }
        }

        return nil
    }
}

// MARK: - Background agents

enum PaceBackgroundAgentCommand {
    case run(prompt: String, displayName: String)
    case list
    case cancel(displayName: String)
}

nonisolated enum PaceBackgroundAgentCommandParser {
    static func parse(_ transcript: String) -> PaceBackgroundAgentCommand? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "list background tasks" / "what's running in the background"
        if (lower.contains("list") || lower.contains("what")) && lower.contains("background") {
            return .list
        }

        // "cancel the background task" / "stop the background agent"
        if (lower.contains("cancel") || lower.contains("stop")) && lower.contains("background") {
            return .cancel(displayName: lower)
        }

        // "in the background, draft a reply to..." / "background: do something"
        if lower.hasPrefix("in the background") || lower.hasPrefix("background:") {
            let prompt = lower
                .replacingOccurrences(of: "in the background", with: "")
                .replacingOccurrences(of: "background:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ", :"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                let displayName = String(prompt.prefix(40))
                return .run(prompt: prompt, displayName: displayName)
            }
        }

        return nil
    }
}

// MARK: - Meeting mode

enum PaceMeetingModeCommand {
    case start
    case stop
    case status
}

nonisolated enum PaceMeetingModeCommandParser {
    static func parse(_ transcript: String) -> PaceMeetingModeCommand? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lower.contains("meeting mode") {
            if lower.contains("start") || lower.contains("begin") || lower.contains("enable") {
                return .start
            }
            if lower.contains("stop") || lower.contains("end") || lower.contains("disable") {
                return .stop
            }
            if lower.contains("status") || lower.contains("is it on") {
                return .status
            }
            // Bare "meeting mode" toggles.
            return .start
        }

        return nil
    }
}

// MARK: - Skills

enum PaceSkillCommand {
    case list
    case run(slug: String, name: String)
    case install(slug: String, name: String)
}

nonisolated enum PaceSkillCommandParser {
    static func parse(_ transcript: String) -> PaceSkillCommand? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "list skills" / "what skills do you have"
        if (lower.contains("list") || lower.contains("what")) && lower.contains("skill") {
            return .list
        }

        // "install the standup skill" / "add the standup notes skill"
        if (lower.hasPrefix("install ") || lower.hasPrefix("add ")) && lower.contains("skill") {
            let name = lower
                .replacingOccurrences(of: "install the ", with: "")
                .replacingOccurrences(of: "install ", with: "")
                .replacingOccurrences(of: "add the ", with: "")
                .replacingOccurrences(of: "add ", with: "")
                .replacingOccurrences(of: " skill", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let slug = name.replacingOccurrences(of: " ", with: "-")
                return .install(slug: slug, name: name)
            }
        }

        // "run the standup skill" / "execute the standup notes skill"
        if (lower.hasPrefix("run ") || lower.hasPrefix("execute ")) && lower.contains("skill") {
            let name = lower
                .replacingOccurrences(of: "run the ", with: "")
                .replacingOccurrences(of: "run ", with: "")
                .replacingOccurrences(of: "execute the ", with: "")
                .replacingOccurrences(of: "execute ", with: "")
                .replacingOccurrences(of: " skill", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let slug = name.replacingOccurrences(of: " ", with: "-")
                return .run(slug: slug, name: name)
            }
        }

        return nil
    }
}
