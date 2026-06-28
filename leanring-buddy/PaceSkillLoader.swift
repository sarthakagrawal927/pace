//
//  PaceSkillLoader.swift
//  leanring-buddy
//
//  Loads .skill.md files (Claude Code / OpenFelix compatible format)
//  and converts them to PaceRecordedFlow recipes. Inspired by
//  OpenFelix/OpenClicky's SKILL.md system.
//
//  .skill.md format:
//  ---
//  name: "Skill Name"
//  slug: "skill-slug"
//  description: "One-line description"
//  category: "morning" | "work" | "shutdown" | "custom"
//  requiredPreferences: ["preferredNotesFolder"]
//  trigger: "optional voice trigger phrase"
//  ---
//
//  ## Steps
//  1. Open Notes app
//  2. Create new note titled "Standup - {date}"
//  3. Add sections: Yesterday, Today, Blockers
//
//  ## Notes
//  Optional context for the planner.
//

import Foundation

/// Parsed .skill.md file.
struct PaceSkillFile: Codable, Equatable {
    let name: String
    let slug: String
    let description: String
    let category: String
    let requiredPreferences: [String]
    let trigger: String?
    let steps: [PaceSkillStep]
    let notes: String?
}

/// A single step in a skill file.
struct PaceSkillStep: Codable, Equatable {
    let instruction: String
    /// Optional tool call JSON (if the step is a direct tool call
    /// rather than a natural-language instruction).
    let toolCall: String?
}

/// Loader for .skill.md files. Scans the bundled Resources/skills/
/// directory and the user's ~/Library/Application Support/Pace/skills/
/// directory for .skill.md files, parses them, and converts them to
/// PaceRecordedFlow recipes that can be installed via the existing
/// recipe library.
enum PaceSkillLoader {

    /// Load all .skill.md files from bundled and user directories.
    static func loadAllSkills() -> [PaceSkillFile] {
        var skills: [PaceSkillFile] = []

        // Bundled skills (Resources/skills/*.skill.md)
        if let bundledSkills = loadSkillsFromDirectory(bundledSkillsDirectory()) {
            skills.append(contentsOf: bundledSkills)
        }

        // User skills (~/Library/Application Support/Pace/skills/*.skill.md)
        if let userSkills = loadSkillsFromDirectory(userSkillsDirectory()) {
            skills.append(contentsOf: userSkills)
        }

        return skills
    }

    /// Parse a single .skill.md file from its raw content.
    static func parse(skillMarkdown: String, fallbackSlug: String = "") -> PaceSkillFile? {
        // Split frontmatter and body.
        guard skillMarkdown.hasPrefix("---") else { return nil }
        let afterFirstDelimiter = String(skillMarkdown.dropFirst(3))
        guard let endRange = afterFirstDelimiter.range(of: "\n---\n") else { return nil }
        let frontmatter = String(afterFirstDelimiter[..<endRange.lowerBound])
        let body = String(afterFirstDelimiter[endRange.upperBound...])

        // Parse frontmatter as simple key: value pairs.
        var name = ""
        var slug = fallbackSlug
        var description = ""
        var category = "custom"
        var requiredPreferences: [String] = []
        var trigger: String?

        for line in frontmatter.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch key {
            case "name": name = value
            case "slug": slug = value
            case "description": description = value
            case "category": category = value
            case "requiredPreferences":
                // Parse as JSON array or comma-separated list.
                requiredPreferences = parseStringArray(value)
            case "trigger": trigger = value.isEmpty ? nil : value
            default: break
            }
        }

        guard !name.isEmpty, !slug.isEmpty else { return nil }

        // Parse steps from the body.
        let (steps, notes) = parseBody(body)

        guard !steps.isEmpty else { return nil }

        return PaceSkillFile(
            name: name,
            slug: slug,
            description: description.isEmpty ? name : description,
            category: category,
            requiredPreferences: requiredPreferences,
            trigger: trigger,
            steps: steps,
            notes: notes
        )
    }

    /// Convert a PaceSkillFile's steps into a planner prompt that
    /// the agent loop can execute. Unlike recipes (which are recorded
    /// UI actions replayed verbatim), skills are natural-language
    /// instructions that the planner interprets and executes step by
    /// step — more flexible and more resilient to UI changes.
    static func toPlannerPrompt(_ skill: PaceSkillFile) -> String {
        var prompt = "Execute the \"\(skill.name)\" skill. Follow these steps:\n\n"
        for (index, step) in skill.steps.enumerated() {
            prompt += "\(index + 1). \(step.instruction)\n"
        }
        if let notes = skill.notes, !notes.isEmpty {
            prompt += "\nContext: \(notes)\n"
        }
        return prompt
    }

    // MARK: - Private helpers

    private static func loadSkillsFromDirectory(_ directory: URL) -> [PaceSkillFile]? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        var skills: [PaceSkillFile] = []
        for entry in entries where entry.pathExtension == "md" {
            guard let content = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            let fallbackSlug = entry.deletingPathExtension().lastPathComponent
            if let skill = parse(skillMarkdown: content, fallbackSlug: fallbackSlug) {
                skills.append(skill)
            }
        }
        return skills.isEmpty ? nil : skills
    }

    private static func bundledSkillsDirectory() -> URL {
        // In the app bundle, skills live in Resources/skills/
        Bundle.main.resourceURL?
            .appendingPathComponent("skills", isDirectory: true)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    private static func userSkillsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    private static func parseStringArray(_ value: String) -> [String] {
        // Try JSON array first.
        if let data = value.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            return array
        }
        // Fall back to comma-separated.
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseBody(_ body: String) -> (steps: [PaceSkillStep], notes: String?) {
        var steps: [PaceSkillStep] = []
        var notes: String?

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var inStepsSection = false
        var inNotesSection = false
        var notesLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("## ") {
                let heading = String(trimmed.dropFirst(3)).lowercased()
                inStepsSection = heading.contains("step")
                inNotesSection = heading.contains("note")
                continue
            }

            if inStepsSection {
                // Match numbered list items: "1. Do something"
                if let dotIndex = trimmed.firstIndex(of: ".") {
                    let prefix = String(trimmed[..<dotIndex])
                    if Int(prefix.trimmingCharacters(in: .whitespaces)) != nil {
                        let instruction = String(trimmed[trimmed.index(after: dotIndex)...])
                            .trimmingCharacters(in: .whitespaces)
                        if !instruction.isEmpty {
                            // Check for tool call in code block.
                            let toolCall = extractToolCall(from: instruction)
                            steps.append(PaceSkillStep(
                                instruction: toolCall == nil ? instruction : instruction,
                                toolCall: toolCall
                            ))
                        }
                    }
                }
            } else if inNotesSection {
                if !trimmed.isEmpty {
                    notesLines.append(trimmed)
                }
            }
        }

        if !notesLines.isEmpty {
            notes = notesLines.joined(separator: " ")
        }

        return (steps, notes)
    }

    /// Extract a tool call JSON from a code block in the instruction.
    private static func extractToolCall(from instruction: String) -> String? {
        // Look for ```json ... ``` blocks.
        guard let startRange = instruction.range(of: "```json") else {
            return nil
        }
        let searchStart = startRange.upperBound
        guard let endRange = instruction.range(of: "```", range: searchStart..<instruction.endIndex) else {
            return nil
        }
        let jsonContent = instruction[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return jsonContent.isEmpty ? nil : jsonContent
    }
}
