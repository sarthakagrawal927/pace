# Project Minimi RAG Snapshot

Fetched: 2026-06-09
Source: https://www.projectminimi.com/

## Product Positioning

Project Minimi is positioned as ambient memory for Claude on Mac. The homepage
claims it quietly captures Mac activity across tabs, documents, calls, and Slack
threads, then exposes that memory to Claude as live context through a custom
connector/MCP-style link.

## Core Workflow

1. Install the Mac app and sign in.
2. Copy a Minimi MCP/custom connector link into Claude.
3. Ask Claude questions that rely on the captured activity history.

Example use cases on the homepage include finding a previously read article,
recalling meeting decisions and action items, reconstructing what the user did
today, finding everything read about a topic, and identifying where the user
left off.

## Memory And Retrieval Claims

Minimi says the memory lives on the user's Mac and uses a vector database stored
locally. The homepage also claims a BEAM benchmark result of 54% for Minimi
versus 36% for LIGHT, described as 50% more accurate than the previous SOTA.

## Privacy And Architecture Notes

The homepage says nothing is stored in the cloud, but also says Gemini makes the
embeddings for Minimi on a paid plan. The same page describes memory in transit
to the LLM as decrypted before processing and encrypted again on the way back to
the device. This is important competitive context for Pace: Minimi is not a pure
local-only architecture if embeddings or memory context leave the Mac.

The privacy policy is broader and says personal data and usage data may be
collected, service providers may process data, information may be uploaded to
company or service-provider servers, and data may be transferred across
jurisdictions. The limited-use disclosure says Shram's use of Google API data
will follow Google's API Services User Data Policy.

## Pace Relevance

Directly relevant to Pace's local RAG direction:

- Same broad wedge: personal/ambient memory for assistant context.
- Minimi talks to Claude rather than replacing Claude.
- Minimi emphasizes Mac-native ambient capture and memory retrieval.
- Pace should preserve a stronger claim: local-only by architecture, with no
  cloud embeddings and no cloud LLM fallback.
- Pace's RAG should answer questions such as "how does Pace differ from Minimi",
  "what is Minimi's privacy gap", and "why does Pace avoid cloud embeddings".

