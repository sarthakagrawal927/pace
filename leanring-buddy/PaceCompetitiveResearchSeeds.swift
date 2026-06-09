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

    static var documents: [PaceRetrievalDocument] {
        [projectMinimi]
    }
}

