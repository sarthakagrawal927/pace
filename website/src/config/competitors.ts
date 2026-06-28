// Competitor registry for the /compared page.
//
// Single source of truth for the "Pace vs the field" comparison.
// To add a new entry, append one object to the array — the page
// renders automatically. Recheck the `rechecked` field at the
// bottom whenever you touch anything.
//
// Honesty rules (matches the tone of Comparison.astro):
//   - `standoutFeatures` are the things each product genuinely does
//     well, written like someone who actually uses it. No strawmen.
//   - `paceDiffers` is one honest sentence on where Pace diverges —
//     including cases where Pace is behind.
//   - `openSource` reflects the *current* shipping product, not a
//     legacy fork. If the original was OSS but the maintained
//     version went closed, mark `openSource: false` and note the
//     legacy repo in `repoUrl`.

export type Posture = "on-device" | "cloud" | "hybrid";
export type License =
  | "MIT"
  | "Apache-2.0"
  | "Source-available"
  | "Proprietary"
  | "No license yet";

export interface Competitor {
  /** Display name. */
  name: string;
  /** One-line tagline, the way the product describes itself. */
  tagline: string;
  /** Author / maintainer handle or org. */
  author: string;
  /** Primary repo or homepage. */
  url: string;
  /** Is the *current* shipping product open source? */
  openSource: boolean;
  /** License label. "No license yet" = all rights reserved by default. */
  license: License;
  /** Where inference runs. */
  posture: Posture;
  /** STT provider, short. */
  stt: string;
  /** Reasoning model / provider, short. */
  reasoner: string;
  /** TTS provider, short. */
  tts: string;
  /** Reads the screen? */
  screenAware: boolean;
  /** The 2–4 things this product genuinely does best. */
  standoutFeatures: string[];
  /** One honest sentence on where Pace differs — including where Pace is behind. */
  paceDiffers: string;
}

export const competitors: Competitor[] = [
  {
    name: "Clicky / HeyClicky",
    tagline: "AI teacher that lives next to your cursor.",
    author: "Farza Majeed",
    url: "https://www.heyclicky.com/",
    openSource: false,
    license: "Proprietary",
    posture: "cloud",
    stt: "AssemblyAI streaming",
    reasoner: "Claude Sonnet 4.6 (SSE)",
    tts: "ElevenLabs",
    screenAware: true,
    standoutFeatures: [
      "Background agents that run while you keep working — build a Mac app, file a Linear ticket, draft a Gmail.",
      "YC S26, $10.1M raised, $20/mo Pro tier — the polished, distributed one.",
      "Native Notion / Gmail / Google Calendar / Linear integrations out of the box.",
    ],
    paceDiffers:
      "Pace is fully on-device and one-time $29; Clicky is cloud-per-turn and a subscription. Clicky's background agents and onboarding polish are ahead of Pace today.",
  },
  {
    name: "OpenClicky",
    tagline: "The other open-source Clicky fork, by Jason Kneen.",
    author: "Jason Kneen",
    url: "https://github.com/jasonkneen/openclicky",
    openSource: true,
    license: "MIT",
    posture: "hybrid",
    stt: "Configurable (AssemblyAI / OpenAI / Apple)",
    reasoner: "Claude or local",
    tts: "ElevenLabs or local",
    screenAware: true,
    standoutFeatures: [
      "Sparkle OTA updates via signed appcast.xml — real auto-update distribution.",
      "Agent Mode dashboard for coding, research, writing, and automation tasks.",
      "Bundled skills, wiki seed, and Codex runtime in AppResources.",
    ],
    paceDiffers:
      "Pace is on-device-first with a tier picker; OpenClicky defaults to Claude + ElevenLabs. OpenClicky ships a signed DMG with Sparkle updates — Pace is still build-from-Xcode.",
  },
  {
    name: "Ora",
    tagline: "Privacy-first macOS voice assistant, on-device AI.",
    author: "benedict2310",
    url: "https://github.com/benedict2310/ora",
    openSource: false,
    license: "Source-available",
    posture: "on-device",
    stt: "Parakeet (local)",
    reasoner: "MLX + Qwen 3.5 VL",
    tts: "Kokoro",
    screenAware: true,
    standoutFeatures: [
      "Closest philosophical twin to Pace — fully local pipeline: Parakeet ASR → MLX Qwen 3.5 VL → Kokoro TTS.",
      "Streaming pipeline with live transcription, streaming LLM tokens, and early TTS start.",
      "Agentic tools across Calendar, Reminders, Contacts, Mail, Messages, Notes, and System.",
      "Sparkle auto-updates and a downloadable release.",
    ],
    paceDiffers:
      "Pace adds a tier picker (Local / CLI bridge / Direct API / Apple FM) with byte-identical persona across tiers, visible-undo trust surfaces, and two-tier thread memory that survives quit/relaunch. Ora is single-tier local.",
  },
  {
    name: "OpenFelix",
    tagline: "Voice-first AI agent for macOS that actually runs locally.",
    author: "fspecii / @AmbsdOP",
    url: "https://github.com/fspecii/openfelix",
    openSource: true,
    license: "Apache-2.0",
    posture: "on-device",
    stt: "On-device (Option+Space)",
    reasoner: "MLX (Qwen / Mistral)",
    tts: "Local",
    screenAware: true,
    standoutFeatures: [
      "Cron jobs — schedule tasks with `daily@09:00`, `every:30m`, `once:ISO8601`.",
      "Proactive alerts pushed to Telegram, Discord, and Slack.",
      "Music generation via ACE-Step and YouTube spoken summaries.",
      "Skill system that extends the agent to anything.",
    ],
    paceDiffers:
      "Pace has MCP integration, a recipe library, and passive time-understanding journals (screen watch + app usage). OpenFelix leans into scheduled + proactive surfaces Pace doesn't ship yet.",
  },
  {
    name: "ORB",
    tagline: "Fully on-device voice agent — hears, sees, operates your Mac.",
    author: "settylokesh",
    url: "https://github.com/settylokesh/ORB",
    openSource: false,
    license: "No license yet",
    posture: "on-device",
    stt: "Moonshine (ONNX Runtime)",
    reasoner: "Gemma 4 E4B (4-bit, MLX)",
    tts: "Local",
    screenAware: true,
    standoutFeatures: [
      "Structured JSON action plans emitted by the VLM — explicit plan-then-execute loop.",
      "ONNX Runtime + MLX dual runtime — Moonshine for ASR, MLX for the VLM.",
      "Glow border around the screen to signal listening / planning / executing phases.",
    ],
    paceDiffers:
      "Pace uses a heavier qwen3-30b-a3b reasoner with a tier picker and trust surfaces. ORB is leaner and more single-purpose. Note: ORB has no license file yet, so it's effectively all-rights-reserved.",
  },
  {
    name: "Impulse",
    tagline: "Native macOS assistant — sees, hears, remembers your projects.",
    author: "section9-lab",
    url: "https://github.com/section9-lab/Impulse",
    openSource: true,
    license: "Apache-2.0",
    posture: "hybrid",
    stt: "Speech framework (on-device)",
    reasoner: "Any OpenAI-compatible / Ollama / LM Studio",
    tts: "Local",
    screenAware: true,
    standoutFeatures: [
      "Per-project SwiftData memory — conversations scoped to the project you're working in.",
      "JSONL session logs that are diffable and greppable.",
      "Vision framework OCR on-device; security-scoped bookmarks for sandboxed file access.",
      "Tool calls are visible in chat before they run.",
    ],
    paceDiffers:
      "Pace's memory is conversation-wide two-tier (verbatim K=4 + rolling summary) with cross-quit persistence. Impulse's is per-project SwiftData. Pace adds actions, MCP, and a tier picker; Impulse is more focused on project-scoped chat.",
  },
  {
    name: "Agent! (macOS26)",
    tagline: "18 LLM providers, hotword-anchored, free on Apple Intelligence.",
    author: "macOS26 / Todd Bruss",
    url: "https://github.com/macOS26/agent",
    openSource: true,
    license: "MIT",
    posture: "hybrid",
    stt: "SFSpeechRecognizer hotword",
    reasoner: "18 providers (Claude / GPT / Gemini / Grok / … / Apple FM / Ollama / vLLM / LM Studio)",
    tts: "Local",
    screenAware: true,
    standoutFeatures: [
      "Hotword-anchored dictation — say \"Agent!\" from across the room, hands-free.",
      "18 LLM providers wired in, BYO key, free forever on Apple Intelligence.",
      "Apple AI as a real tool-calling agent — multi-step local tool calls, falls through to cloud only on failure.",
    ],
    paceDiffers:
      "Pace is push-to-talk only (no hotword) and ships a tighter on-device default. Agent! wins on hands-free wake and provider breadth; Pace wins on trust surfaces, memory design, and the on-device-first posture being the default rather than one of 18 options.",
  },
  {
    name: "Cursor Voice",
    tagline: "Native macOS voice assistant next to your cursor, powered by OpenAI Realtime API.",
    author: "cursorvoice",
    url: "https://github.com/cursorvoice/cursor-voice",
    openSource: true,
    license: "MIT",
    posture: "cloud",
    stt: "OpenAI Realtime API",
    reasoner: "OpenAI Realtime API (gpt-realtime)",
    tts: "OpenAI Realtime API (built-in voices)",
    screenAware: true,
    standoutFeatures: [
      "Barge-in with echo rejection — interrupt the AI mid-response by talking over it.",
      "On-device wake word (\"Hey Cursor\") via SFSpeechRecognizer, then cloud Realtime API for the conversation.",
      "Built-in web_search tool without requiring an API key.",
    ],
    paceDiffers:
      "Pace is fully on-device; Cursor Voice round-trips every turn through OpenAI's Realtime API. Cursor Voice has barge-in and wake word — both things Pace lacks. Pace wins on privacy and zero per-turn cost.",
  },
  {
    name: "Dottie",
    tagline: "Free AI voice assistant — talk to your Mac, watch it work.",
    author: "stevederico",
    url: "https://www.dottie.ai",
    openSource: false,
    license: "Proprietary",
    posture: "hybrid",
    stt: "Local (MLX-based)",
    reasoner: "Local MLX (3,800+ models) or cloud (OpenAI / Anthropic / xAI / Ollama)",
    tts: "MLX Kokoro with premium AI voices",
    screenAware: true,
    standoutFeatures: [
      "134 built-in system tools for email, calendar, iMessage, music, and files.",
      "Bundled inference stack with zero external dependencies — local Agent API on localhost.",
      "\"Hey Dottie\" wake word + hold-to-dictate (Fn key).",
    ],
    paceDiffers:
      "Dottie ships 134 tools and a wake word — both ahead of Pace. The desktop app source is not public (only the dotbot SDK engine is MIT). Pace is fully open source with a tier picker and trust surfaces Dottie doesn't surface.",
  },
  {
    name: "Fazm",
    tagline: "The fastest AI computer agent — controls your browser, writes code, handles documents.",
    author: "mediar-ai",
    url: "https://github.com/mediar-ai/fazm",
    openSource: true,
    license: "MIT",
    posture: "hybrid",
    stt: "Deepgram Nova-3 (streaming WebSocket)",
    reasoner: "Claude (via ACP bridge)",
    tts: "Deepgram Aura (7 languages)",
    screenAware: true,
    standoutFeatures: [
      "Controls 300+ macOS apps via the Accessibility API — not screenshots, the structured UI tree.",
      "Multi-language architecture: Swift desktop + TypeScript ACP bridge + Rust backend.",
      "Real Chrome session automation — Gmail, Drive, Docs, Sheets, Calendar, WhatsApp.",
    ],
    paceDiffers:
      "Fazm uses the Accessibility API for screen understanding (more reliable, more token-efficient than Pace's VLM-screenshot approach). But Fazm's STT and TTS go through Deepgram's cloud despite 'local' marketing. Pace is fully on-device, including speech.",
  },
  {
    name: "Vox",
    tagline: "The first local AI that actually does things on your Mac — no cloud, no subscription.",
    author: "vox-ai-app",
    url: "https://github.com/vox-ai-app/vox",
    openSource: true,
    license: "MIT",
    posture: "on-device",
    stt: "Local (via llama.cpp)",
    reasoner: "Local (llama.cpp)",
    tts: "Local",
    screenAware: true,
    standoutFeatures: [
      "48 built-in tools for email, iMessage, file management, and screen control.",
      "Passphrase mode — text your Mac from any phone and get AI responses.",
      "MCP client with stdio, SSE, and HTTP support + wake word with barge-in.",
    ],
    paceDiffers:
      "Vox is a true on-device peer to Pace with 48 tools and a passphrase mode Pace doesn't have. Pace has the tier picker, two-tier thread memory, recipe library, and watch mode that Vox doesn't ship. Both are MIT and fully local.",
  },
  {
    name: "RCLI",
    tagline: "Talk to your Mac, query your docs — on-device voice AI + RAG, no cloud required.",
    author: "RunanywhereAI",
    url: "https://github.com/RunanywhereAI/RCLI",
    openSource: true,
    license: "MIT",
    posture: "on-device",
    stt: "Local — Zipformer (streaming), Whisper base.en, Parakeet TDT 0.6B",
    reasoner: "Local — Qwen3 0.6B/4B, Llama 3.2 3B, LFM2.5 1.2B (MetalRT or llama.cpp)",
    tts: "Local — Piper, KittenTTS, Matcha, Kokoro (28 voices)",
    screenAware: true,
    standoutFeatures: [
      "Sub-200ms end-to-end voice latency via proprietary MetalRT GPU engine (up to 550 tok/s).",
      "Local RAG over documents with hybrid vector + BM25 retrieval.",
      "20+ models across LLM, STT, TTS, VLM, VAD, and embeddings — all on-device.",
    ],
    paceDiffers:
      "RCLI's MetalRT engine hits sub-200ms latency and 550 tok/s — a serious performance benchmark Pace should measure against. RCLI has local RAG Pace doesn't ship. Pace has the tier picker, trust surfaces, and MCP integration RCLI lacks. 1,523 stars — the most-trafficked on-device competitor.",
  },
  {
    name: "Samuel",
    tagline: "Voice-first AI companion — wake-word activated, sees screen, hears system audio, writes plugins.",
    author: "sambuild04",
    url: "https://github.com/sambuild04/screen-voice-agent",
    openSource: true,
    license: "MIT",
    posture: "cloud",
    stt: "OpenAI Realtime API",
    reasoner: "OpenAI Realtime API + GPT-5.5 (plugin generation) + GPT-4o Vision",
    tts: "OpenAI Realtime API",
    screenAware: true,
    standoutFeatures: [
      "Self-modifying — writes and hot-loads its own plugins at runtime using GPT-5.5.",
      "Auto-repair — detects plugin failures and patches code automatically (up to 2 attempts).",
      "Hears system audio via ScreenCaptureKit with PID-level filtering, not just microphone.",
    ],
    paceDiffers:
      "Samuel's self-modifying plugin system and system-audio listening are genuinely novel — Pace has neither. But Samuel is fully cloud (OpenAI APIs). Pace is fully on-device. The plugin auto-repair loop is the most interesting idea here.",
  },
  {
    name: "Shiro",
    tagline: "Local-first autonomous agent — watches screen, spawns parallel sub-agents, MCP ecosystem.",
    author: "abhisheksharma001",
    url: "https://github.com/abhisheksharma001/shiro",
    openSource: true,
    license: "MIT",
    posture: "hybrid",
    stt: "Deepgram Nova-3 (meeting mode)",
    reasoner: "Local-first (LM Studio / Ollama) with Claude fallback",
    tts: "Local",
    screenAware: true,
    standoutFeatures: [
      "Parallel sub-agents with atomic SQL checkout, persona injection, depth & budget guards.",
      "Hybrid RAG using sqlite-vec + FTS5 in one SQLite file — live knowledge graph updates on every tool call.",
      "Meeting mode with ScreenCaptureKit audio capture + live action item extraction.",
    ],
    paceDiffers:
      "Shiro's parallel sub-agents and hybrid RAG knowledge graph are architecturally beyond Pace's single-thread agent loop. Pace has the tier picker, trust surfaces, and recipe library Shiro doesn't ship. Shiro's meeting mode is a surface Pace could add.",
  },
  {
    name: "LocalNotch",
    tagline: "Local AI assistant that lives in your MacBook's notch — chat, vision, file agent, all on-device.",
    author: "arshawnarbabi",
    url: "https://github.com/arshawnarbabi/LocalNotch",
    openSource: true,
    license: "MIT",
    posture: "on-device",
    stt: "None (text and image input only)",
    reasoner: "Local (Ollama — user selects model)",
    tts: "None (text output only)",
    screenAware: true,
    standoutFeatures: [
      "Lives in the MacBook notch — hover to open, type to ask, then disappears. No window management.",
      "Autonomous file-system Agent Mode with approval workflow.",
      "Optional Brave Search with 3-layer hybrid classifier for automatic web search.",
    ],
    paceDiffers:
      "LocalNotch shares Pace's notch surface but is text/image only — no voice input or TTS. It's a different interaction model. Pace is voice-first; LocalNotch is hover-and-type. The notch integration pattern is worth studying.",
  },
];

/** When this comparison was last rechecked. Rendered on the page. */
export const comparisonRechecked = "June 2026";
