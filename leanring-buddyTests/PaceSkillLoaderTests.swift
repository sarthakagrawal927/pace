//
//  PaceSkillLoaderTests.swift
//  leanring-buddyTests
//
//  Tests for the .skill.md parser and planner prompt converter.
//  Verifies that frontmatter, steps, and notes are parsed correctly
//  from the Claude Code / OpenFelix-compatible format.
//

import Foundation
import Testing
@testable import Pace

struct PaceSkillLoaderTests {

    // MARK: - Parsing

    /// A complete .skill.md file with frontmatter and steps parses
    /// correctly.
    @Test
    func parseCompleteSkillFile() {
        let markdown = """
        ---
        name: "Test Skill"
        slug: "test-skill"
        description: "A test skill for unit testing"
        category: "work"
        requiredPreferences: ["preferredNotesFolder"]
        trigger: "run test skill"
        ---

        ## Steps

        1. Open Notes app
        2. Create a new note titled "Test"
        3. Add some content

        ## Notes

        This skill is for testing purposes only.
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.name == "Test Skill")
        #expect(skill?.slug == "test-skill")
        #expect(skill?.description == "A test skill for unit testing")
        #expect(skill?.category == "work")
        #expect(skill?.requiredPreferences == ["preferredNotesFolder"])
        #expect(skill?.trigger == "run test skill")
        #expect(skill?.steps.count == 3)
        #expect(skill?.steps[0].instruction == "Open Notes app")
        #expect(skill?.steps[1].instruction == "Create a new note titled \"Test\"")
        #expect(skill?.steps[2].instruction == "Add some content")
        #expect(skill?.notes == "This skill is for testing purposes only.")
    }

    /// A skill file without a trigger still parses (trigger is optional).
    @Test
    func parseSkillWithoutTrigger() {
        let markdown = """
        ---
        name: "No Trigger Skill"
        slug: "no-trigger"
        description: "Skill without a trigger"
        category: "custom"
        requiredPreferences: []
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.trigger == nil)
        #expect(skill?.steps.count == 1)
    }

    /// A skill file without a slug uses the fallback slug.
    @Test
    func parseSkillWithoutSlugUsesFallback() {
        let markdown = """
        ---
        name: "No Slug Skill"
        description: "Skill without a slug"
        category: "custom"
        requiredPreferences: []
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback-slug")

        #expect(skill != nil)
        #expect(skill?.slug == "fallback-slug")
    }

    /// A skill file with no steps returns nil.
    @Test
    func parseSkillWithNoStepsReturnsNil() {
        let markdown = """
        ---
        name: "Empty Skill"
        slug: "empty"
        description: "Skill with no steps"
        category: "custom"
        requiredPreferences: []
        ---

        ## Notes

        No steps here.
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")
        #expect(skill == nil)
    }

    /// A skill file without frontmatter delimiter returns nil.
    @Test
    func parseSkillWithoutFrontmatterReturnsNil() {
        let markdown = "Just some text without frontmatter."

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")
        #expect(skill == nil)
    }

    /// A skill file with empty name returns nil.
    @Test
    func parseSkillWithEmptyNameReturnsNil() {
        let markdown = """
        ---
        name: ""
        slug: "empty-name"
        description: "Skill with empty name"
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")
        #expect(skill == nil)
    }

    /// Required preferences can be parsed as a JSON array.
    @Test
    func parseRequiredPreferencesAsJSONArray() {
        let markdown = """
        ---
        name: "Array Prefs"
        slug: "array-prefs"
        description: "Skill with array prefs"
        requiredPreferences: ["key1", "key2", "key3"]
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.requiredPreferences == ["key1", "key2", "key3"])
    }

    /// Required preferences can be parsed as a comma-separated list.
    @Test
    func parseRequiredPreferencesAsCommaSeparated() {
        let markdown = """
        ---
        name: "Comma Prefs"
        slug: "comma-prefs"
        description: "Skill with comma prefs"
        requiredPreferences: key1, key2, key3
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.requiredPreferences == ["key1", "key2", "key3"])
    }

    /// A skill with a description that defaults to name when empty.
    @Test
    func emptyDescriptionDefaultsToName() {
        let markdown = """
        ---
        name: "Named Skill"
        slug: "named"
        description: ""
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.description == "Named Skill")
    }

    // MARK: - Planner prompt conversion

    /// The planner prompt includes the skill name, numbered steps,
    /// and notes.
    @Test
    func toPlannerPromptIncludesAllElements() {
        let skill = PaceSkillFile(
            name: "Test Skill",
            slug: "test-skill",
            description: "A test",
            category: "work",
            requiredPreferences: [],
            trigger: nil,
            steps: [
                PaceSkillStep(instruction: "First step", toolCall: nil),
                PaceSkillStep(instruction: "Second step", toolCall: nil),
                PaceSkillStep(instruction: "Third step", toolCall: nil),
            ],
            notes: "Important context"
        )

        let prompt = PaceSkillLoader.toPlannerPrompt(skill)

        #expect(prompt.contains("Test Skill"))
        #expect(prompt.contains("1. First step"))
        #expect(prompt.contains("2. Second step"))
        #expect(prompt.contains("3. Third step"))
        #expect(prompt.contains("Important context"))
    }

    /// The planner prompt works with a single step.
    @Test
    func toPlannerPromptWithSingleStep() {
        let skill = PaceSkillFile(
            name: "Simple",
            slug: "simple",
            description: "Simple",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Just do it", toolCall: nil)],
            notes: nil
        )

        let prompt = PaceSkillLoader.toPlannerPrompt(skill)

        #expect(prompt.contains("Simple"))
        #expect(prompt.contains("1. Just do it"))
        #expect(!prompt.contains("Context:"))
    }

    /// The planner prompt omits the notes section when nil.
    @Test
    func toPlannerPromptOmitsNilNotes() {
        let skill = PaceSkillFile(
            name: "No Notes",
            slug: "no-notes",
            description: "No notes",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Step", toolCall: nil)],
            notes: nil
        )

        let prompt = PaceSkillLoader.toPlannerPrompt(skill)

        #expect(!prompt.contains("Context:"))
    }

    // MARK: - Sample bundled skill

    /// The bundled sample skill file parses correctly.
    @Test
    func bundledSampleSkillParses() {
        let markdown = """
        ---
        name: "Standup Notes"
        slug: "standup-notes"
        description: "Creates a standup notes document with Yesterday, Today, Blockers sections"
        category: "morning"
        requiredPreferences: []
        trigger: "prepare my standup"
        ---

        ## Steps

        1. Open Notes app
        2. Create a new note titled "Standup - {today's date}"
        3. Add a heading "Yesterday" and list what I accomplished yesterday
        4. Add a heading "Today" and list my planned tasks for today
        5. Add a heading "Blockers" and note any blocking issues

        ## Notes

        This skill helps prepare for daily standup meetings by organizing thoughts into the three standard sections.
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "standup-notes")

        #expect(skill != nil)
        #expect(skill?.name == "Standup Notes")
        #expect(skill?.slug == "standup-notes")
        #expect(skill?.category == "morning")
        #expect(skill?.trigger == "prepare my standup")
        #expect(skill?.steps.count == 5)
        #expect(skill?.steps[0].instruction == "Open Notes app")
    }
}
