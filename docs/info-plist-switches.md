# Pace - Info.plist switch reference (local mode)

<!-- Canonical home for the local-mode Info.plist switch table. Linked from AGENTS.md → Architecture → Local-mode setup, and from SETUP_LOCAL.md. -->

See [`SETUP_LOCAL.md`](../SETUP_LOCAL.md) for the full local-mode recipe. This is the canonical summary of the Info.plist switches that control local VLM / planner / TTS / transcription behavior; it was relocated here from [`AGENTS.md`](../AGENTS.md) to keep the agent-instructions file lean.

| Key | Default | Effect when changed |
|---|---|---|
| `UseLocalVLMForScreenContext` | `true` | `false` to skip the VLM call and send the raw transcript to the planner. |
| `ScreenAnalysisProvider` | `lmStudio` | `inProcess` / `coreML` / `mlx` select the in-process VLM placeholder and currently fall back to LM Studio HTTP until the runtime bridge is wired. |
| `LocalVLMBaseURL` | `http://localhost:1234/v1` | OpenAI-compatible root for the local VLM. Must be loopback (`localhost`, `127.0.0.0/8`, or `::1`); remote/LAN hosts are refused. |
| `LocalVLMModelIdentifier` | `ui-venus-1.5-2b` | Must match the model name loaded in LM Studio. 2B GUI specialist; the OCR layer fills in text fidelity the smaller model would miss. |
| `AlwaysRunLocalVLMRegardlessOfTranscript` | `false` | `true` → bypass the VLM-skip heuristic, run VLM on every turn |
| `LocalPlannerBaseURL` | `http://localhost:1234/v1` | OpenAI-compatible root for the local reasoner. Must be loopback (`localhost`, `127.0.0.0/8`, or `::1`); remote/LAN hosts are refused. |
| `LocalPlannerModelIdentifier` | `google/gemma-3-12b` | Must match the model name loaded in LM Studio for the planner role. Gemma-3-12B-it (qat-4bit, ~8 GB) is the eval-validated default (2026-06-12 drilldown: only ≤14B model beating the 4B baseline on clarify + out-of-scope + destructive-confirm); swap down to `qwen3-4b-instruct` for tighter RAM, or `qwen/qwen3-30b-a3b` for stronger multi-step reasoning on 48 GB machines. |
| `EnableActions` | `true` | `false` → parse action tags but do not execute local macOS actions. Keep `Approve Risky Actions` on when this is true. |
| `AgentMaxSteps` | `8` | Per-task ceiling for the plan-act-observe loop. `1` disables multi-step (loop exits after first response). |
| `TTSProvider` | `localServer` | `apple` → always use `AVSpeechSynthesizer` directly. `localServer` uses the Kokoro sidecar with automatic per-utterance Apple fallback. |
| `LocalTTSServerBaseURL` | `http://localhost:8880/v1` | Loopback-only OpenAI-compatible TTS root (mlx-audio / kokoro-fastapi). |
| `LocalTTSServerModel` | `mlx-community/Kokoro-82M-bf16` | Model identifier the sidecar expects (`kokoro` for kokoro-fastapi). |
| `LocalTTSServerVoice` | `af_heart` | Kokoro voice name. |
| `LocalTTSServerSpeed` | `1.0` | Playback speed multiplier (0.25–4.0). |
| `PushToTalkShortcut` | `controlOption` | One of `controlOption`, `shiftFunction`, `shiftControl`, `controlOptionSpace`, `shiftControlSpace`. Swap if another global dictation tool (e.g. Wispr Flow) is on the same key. |
| `TranscriptionProvider` | `appleSpeech` | `whisperKit` selects the scaffolded WhisperKit provider and currently falls back to Apple Speech until the streaming runtime is wired. |
| `PrewarmMailForDrafts` | `true` | `false` to skip non-activating Mail launch at Pace startup. Keeping it on avoids Mail's cold-launch tax for the streaming draft path. |
| `LocalRetrievalFileRootPaths` | empty | Optional comma/newline-separated explicit roots for file retrieval. With no roots, File retrieval records a skipped status and does not crawl the Mac. |
