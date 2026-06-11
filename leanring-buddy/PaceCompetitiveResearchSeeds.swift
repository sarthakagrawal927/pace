//
//  PaceCompetitiveResearchSeeds.swift
//  leanring-buddy
//
//  Built-in local retrieval snapshots for competitor/product research that
//  should be available without fetching the web at runtime.
//

import Foundation

enum PaceCompetitiveResearchSeeds {
    static let projectMinimi = PaceRetrievalDocument(
        id: "competitive-project-minimi-2026-06-09",
        source: .competitiveResearch,
        title: "Project Minimi: ambient memory for Claude",
        text: """
        Project Minimi RAG snapshot.
        Fetched: 2026-06-09.
        Source: https://www.projectminimi.com/

        Product positioning: Project Minimi is positioned as ambient memory for Claude on Mac. The homepage claims it quietly captures Mac activity across tabs, documents, calls, and Slack threads, then exposes that memory to Claude as live context through a custom connector/MCP-style link.

        Core workflow: install the Mac app and sign in; copy a Minimi MCP/custom connector link into Claude; ask Claude questions that rely on captured activity history.

        Example use cases: finding a previously read article, recalling meeting decisions and action items, reconstructing what the user did today, finding everything read about a topic, and identifying where the user left off.

        Memory and retrieval claims: Minimi says memory lives on the user's Mac and uses a locally stored vector database. The homepage also claims a BEAM benchmark result of 54% for Minimi versus 36% for LIGHT, described as 50% more accurate than the previous SOTA.

        Privacy and architecture notes: the homepage says nothing is stored in the cloud, but also says Gemini makes embeddings for Minimi on a paid plan. The same page describes memory in transit to the LLM as decrypted before processing and encrypted again on the way back to the device. This matters for Pace because Minimi is not a pure local-only architecture if embeddings or memory context leave the Mac.

        Policy notes: the privacy policy says personal data and usage data may be collected, service providers may process data, information may be uploaded to company or service-provider servers, and data may be transferred across jurisdictions. The limited-use disclosure says Shram's use of Google API data will follow Google's API Services User Data Policy.

        Pace relevance: same broad wedge as Pace local RAG; Minimi talks to Claude rather than replacing Claude; Minimi emphasizes Mac-native ambient capture and memory retrieval. Pace should preserve the stronger claim: local-only by architecture, with no cloud embeddings and no cloud LLM fallback. Pace should be able to answer how it differs from Minimi, what Minimi's privacy gap is, and why Pace avoids cloud embeddings.
        """,
        localURL: URL(string: "https://www.projectminimi.com/"),
        modifiedAt: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z"),
        permissionScope: "built-in-competitive-research"
    )

    static let dayflowWorkJournal = PaceRetrievalDocument(
        id: "competitive-dayflow-work-journal-2026-06-10",
        source: .competitiveResearch,
        title: "Dayflow: private automatic work journal for Mac",
        text: """
        Dayflow work journal snapshot.
        Fetched: 2026-06-10.
        Source: https://github.com/JerryZLiu/Dayflow

        Product positioning: Dayflow is a native macOS SwiftUI app that builds a private automatic work journal from screen activity. It captures lightweight screen chunks, analyzes them with a user-chosen AI provider, and turns the day into labeled activity cards on a visual timeline. Open source MIT.

        Core workflow: grant Screen Recording permission; capture at low FPS; batch-analyze every ~15 minutes; synthesize timeline cards with context beyond app names; browse daily standup and weekly review views; export Markdown; chat with the journal in natural language.

        AI providers: local Ollama or LM Studio; Gemini BYO key; ChatGPT or Claude via local CLI tools on paid subscriptions. Cloud or CLI modes send activity data to the provider for analysis; local model mode keeps analysis on the Mac.

        Privacy and storage: recordings and database under ~/Library/Application Support/Dayflow/; configurable cleanup and storage limits; URL schemes dayflow://start-recording and dayflow://stop-recording for Shortcuts and Raycast.

        Pace relevance: Dayflow owns ambient screen memory and work journaling. Pace owns voice-first real-time assistance and local tool execution. Overlap includes screen capture, LM Studio support, and journal-style Q&A. Pace differentiators: fully on-device architecture by default, sub-second voice loop, agent actions (click, type, Mail, Calendar, MCP), and no cloud embedding path. Convergence for Pace: persist watch-mode context into retrieval, answer what did I do today from local history, and add pace:// deeplinks for Shortcuts parity.
        """,
        localURL: URL(string: "https://www.dayflow.so/"),
        modifiedAt: ISO8601DateFormatter().date(from: "2026-06-10T00:00:00Z"),
        permissionScope: "built-in-competitive-research"
    )

    static let localVoiceAssistantCategory = PaceRetrievalDocument(
        id: "competitive-local-voice-assistant-2026-06-10",
        source: .competitiveResearch,
        title: "Local private voice assistant category (Dottie, OpenFelix)",
        text: """
        Local voice assistant category snapshot.
        Fetched: 2026-06-10.
        Sources: dottie.ai, OpenFelix README, Pace landing draft.

        Category: private voice assistant for Mac — menu-bar presence, push-to-talk or wake word, speech-to-text, planner or agent loop, optional screen vision, text-to-speech, and macOS tool execution.

        Dottie: menu-bar coworker; Fn push-to-talk dictation at cursor; Hey Dottie wake word; MLX Kokoro TTS; large agent tool surface; dottie:// URL schemes for Shortcuts (record, chat, type).

        OpenFelix: open-source Swift menu-bar agent; Option+Space voice or text; local MLX models plus optional cloud models; screen vision; cron jobs; proactive Telegram Discord Slack alerts.

        Wispr Flow: cloud dictation round-trip; privacy is policy-based not architectural.

        Pace fits this category but commits to fully on-device speech, vision, reasoning, and TTS with LM Studio loopback planners and Apple Speech STT. Pace already has PTT, streaming TTS, planner tool loop, screen context, MCP bridge, approval gates, and menu-bar panel.

        Gaps vs leaders: pace:// deeplinks not yet shipped; no wake word; agent-first rather than dictation-at-cursor-only mode; watch mode but no proactive outbound alerts; no cloud model option by design.

        Pace differentiation to keep: no cloud LLM STT or TTS path; AX-first local actions; eval-gated planner; loopback-only model endpoints via PaceLocalEndpointGuard. User assistant repo ideas add privacy-first memory visualization, proactive assistant pings, and multi-expert routing as north-star patterns Pace can pursue locally.
        """,
        localURL: URL(string: "https://www.dottie.ai/"),
        modifiedAt: ISO8601DateFormatter().date(from: "2026-06-10T00:00:00Z"),
        permissionScope: "built-in-competitive-research"
    )

    static var documents: [PaceRetrievalDocument] {
        [projectMinimi, dayflowWorkJournal, localVoiceAssistantCategory]
    }
}

