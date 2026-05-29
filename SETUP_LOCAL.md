# Pace-Local Setup

This doc covers the steps to run Pace as a fully on-device agent. STT, TTS, screen analysis, and reasoning all run on your Mac — no cloud LLM, no API keys, no network traffic.

## Quick start (automated)

For first-time setup, run the provisioning script — it installs LM Studio via brew if missing, starts the local server, downloads the VLM, and loads both models with the right context length:

```bash
./scripts/setup-local.sh           # full provision
./scripts/setup-local.sh status    # just print state of the world
```

After the script finishes, just **Cmd+R in Xcode** to build and run. Do NOT use `xcodebuild` from the terminal — it invalidates TCC permissions per `AGENTS.md`. When the app prompts on first launch, grant Microphone, Accessibility, Screen Recording, and Speech Recognition.

WhisperKit is an OPTIONAL alternative STT backend; Apple Speech is the default and needs no SPM dependency. Skip the WhisperKit section below unless you specifically want to swap.

The detailed manual steps below explain what the script does and what to tweak.

## What runs where

| Component | Implementation |
|---|---|
| Speech-to-text | **Apple Speech** (`SFSpeechRecognizer`, on-device) by default. WhisperKit is an optional `whisperkit` backend gated on the SPM dep. |
| Text-to-speech | **AVSpeechSynthesizer** (Apple built-in) — the only TTS path; no cloud option. |
| Screen analysis (VLM) | **LM Studio** at `localhost:1234`, default model `ui-venus-ground-7b` (GUI-specialist, ScreenSpot-v2 ~94). Only invoked when `UseLocalVLMForScreenContext=true`. |
| Reasoning / planning | **LM Studio** at `localhost:1234`, default model `qwen3-30b-a3b-thinking-2507`. `LocalPlannerClient` is the only conformer to `BuddyPlannerClient` today. |
| Click targeting | **AX-tree hybrid** — `PaceAXTargeter` tries `AXUIElementPerformAction` on pressable elements first; falls back to CGEvent when AX can't resolve. |
| Agent loop | **Plan-act-observe** — `CompanionManager` re-screenshots between actions and re-invokes the planner until it emits `[DONE]` or actions stop. Capped at `AgentMaxSteps` (default 8). |
| Real clicks / keystrokes | **PaceActionExecutor** — CGEvent mouse + keyboard with AX-tree pre-pass, gated by Info.plist `EnableActions`. |
| Voice input UI | **Whisper Flow-style pill** — glassmorphic capsule with gradient-bordered bars. |
| Cursor | **Codex-style arrow** — sharp pointer with linear gradient + highlight stroke. |
| Walking avatar | **`PaceAvatarOverlay`** — small character that walks along the bottom of the cursor screen. Click to open the menu-bar panel. Toggleable. |

## 1. (Optional) Add the WhisperKit Swift Package

**Skip this section if you're using the default Apple Speech provider.** WhisperKit is only needed if you want CoreML/ANE Whisper instead of Apple's built-in SFSpeechRecognizer.

Open the Xcode project, then:

1. **File → Add Package Dependencies…**
2. Paste: `https://github.com/argmaxinc/WhisperKit`
3. Choose **Up to Next Major** from the latest tagged release.
4. Add the `WhisperKit` library product to the **leanring-buddy** target.
5. Set `VoiceTranscriptionProvider=whisperkit` in `leanring-buddy/Info.plist`.

The provider source file is gated by `#if canImport(WhisperKit)`, so the build will succeed even if you skip this step. Apple Speech remains active.

## 2. Install LM Studio and load both a VLM and a reasoner

1. Download LM Studio from <https://lmstudio.ai>.
2. In the search tab, download:
   - A vision model: `Qwen3-VL-8B-Instruct` (recommended ~6GB) or `Qwen3-VL-4B-Instruct` (~3GB).
   - A reasoner: `Qwen3-30B-A3B-Thinking-2507` (recommended ~18GB at Q4 — MoE, only 3B params active so it inferences fast despite the size). Smaller fallback: `Qwen3-4B-Instruct` (~2.5GB).
3. Go to **Developer** tab → **Start server** (default port 1234). LM Studio can host multiple models on the same port; load both the VLM and the reasoner. Make sure the identifiers match `LocalVLMModelIdentifier` and `LocalPlannerModelIdentifier` in Info.plist.

Verify the server is up and both models are listed:

```bash
curl -s http://localhost:1234/v1/models | grep -E "qwen3-vl|qwen3-30b|qwen3-4b"
```

## 3. Flip the Info.plist switches

`leanring-buddy/Info.plist` now has these knobs:

| Key | Default | Set to | Effect |
|---|---|---|---|
| `VoiceTranscriptionProvider` | `apple` | `whisperkit` | Apple Speech (`SFSpeechRecognizer`) is the default — instant, on-device, no model download. Set to `whisperkit` to use a downloaded Whisper variant via CoreML/ANE. |
| `WhisperKitModel` | `openai_whisper-large-v3-v20240930_turbo` | same | Which Whisper variant WhisperKit downloads on first push-to-talk (only used when `VoiceTranscriptionProvider=whisperkit`). |
| `UseLocalVLMForScreenContext` | `true` | `false` | Default-on; flip off to skip the VLM call and send the raw transcript straight to the planner. |
| `LocalVLMBaseURL` | `http://localhost:1234/v1` | same | LM Studio OpenAI-compatible root for the VLM |
| `LocalVLMModelIdentifier` | `ui-venus-1.5-8b` | same | Must match the VLM model loaded in LM Studio. Default is UI-Venus-1.5-8B (GUI specialist built on Qwen3-VL, mlx-community 4-bit). |
| `AlwaysRunLocalVLMRegardlessOfTranscript` | `false` | `true` | Forces the VLM to run on every turn even when the transcript looks like pure Q&A. Default off — the VLM-skip heuristic saves perception cost on "what is HTML" style queries. |
| `LocalPlannerBaseURL` | `http://localhost:1234/v1` | same | OpenAI-compatible root for the local reasoner. Often the same LM Studio server as the VLM. |
| `LocalPlannerModelIdentifier` | `qwen/qwen3-14b` | same | Dense 14B is the default — leaner RAM than the 30B MoE despite being "smaller". Swap up (`qwen/qwen3-30b-a3b`, `gpt-oss-20b`) when you want stronger multi-step reasoning, down (`qwen3-4b-instruct`) on tighter hardware. Load with `--num-parallel 1` for the lowest KV-cache footprint. |
| `EnableActions` | `false` | `true` | Allows pace to actually click, type, scroll, and press keys. **Off by default for safety** — only turn on once you've tested without it. |
| `AgentMaxSteps` | `8` | `1`-`30` | Per-task ceiling for the plan-act-observe loop. With this at `1` the loop degrades to the old single-turn behavior. |
| `PushToTalkShortcut` | `controlOption` | one of `controlOption`, `shiftFunction`, `shiftControl`, `controlOptionSpace`, `shiftControlSpace` | Which hold-to-record shortcut Pace listens for. Change this if another dictation tool (Wispr Flow, system Dictation) is on the same key. |

The Info.plist already ships with Apple Speech + on-device TTS as the defaults. Add the VLM layer once STT/TTS is working:

```xml
<key>UseLocalVLMForScreenContext</key>
<string>true</string>
```

## 4. Build and run

```bash
open leanring-buddy.xcodeproj
```

Then Cmd+R in Xcode. **Do not use `xcodebuild` from the terminal** — it invalidates TCC permissions and you'll have to re-grant accessibility, screen recording, etc.

First WhisperKit run will download the model (~1.5 GB for large-v3-turbo) into the app's Documents container. Subsequent launches load from the CoreML cache.

First LM Studio call will be slow (~2-5s cold load). Once the model is hot, expect <2s screenshot-to-element-map on Apple Silicon for the 8B model.

## Action mode (pace actually clicks)

Once `EnableActions=true`, the local planner can emit one or more action tags inline in its response. Tags are parsed out before TTS and executed in order, after the spoken response begins. The cursor flies to the first click target via the same bezier animation that already powers `[POINT:...]`.

| Tag | What it does |
|---|---|
| `[CLICK:x,y]` or `[CLICK:x,y:screen2]` | Single left-click at screenshot pixel (x,y) |
| `[DOUBLE_CLICK:x,y]` | Double-click at the same coord space |
| `[TYPE:exact text]` | Types the literal text into the focused field, unicode safe |
| `[KEY:Return]` / `[KEY:cmd+s]` / `[KEY:cmd+shift+t]` | Press a named key with optional modifier chain |
| `[SCROLL:up:3]` / `[SCROLL:down:5]` | Scroll vertical by N lines |

Multiple tags chain in a single response — for example `[CLICK:400,300][TYPE:hello][KEY:Return]`.

Safety:
- **Default off.** `EnableActions=false` parses tags but never executes — useful for dry-runs so you can read the Xcode console and see what *would* have happened.
- **Speech happens first.** TTS playback starts before the synthetic events fire, giving you ~350ms to release-press the hotkey and interrupt if the planner misjudged.
- **Plan-act-observe loop on by default** (since `AgentMaxSteps=8`). Each step gets a fresh screenshot so the planner course-corrects. Press the hotkey again to cancel the in-flight loop.
- **AX-tree targeting** runs before CGEvent for single-clicks. When the planner aims at a real button/link/menu-item, the click happens via `AXUIElementPerformAction` — more semantically correct and immune to small layout shifts. CGEvent is the fallback when AX can't resolve.
- **The planner controls when to stop.** It must emit `[DONE]` to exit the loop. If it doesn't, the loop bails at `AgentMaxSteps`.
- **A local model is more likely to misjudge than a frontier cloud model.** That's the trade for full on-device independence. Tune by swapping in a stronger reasoner if your hardware allows, or by tightening the system prompt for the workflows you care about.

## Running on lower-end Macs

The local stack can be tuned for tighter RAM budgets without code changes — every model choice is an Info.plist value.

**VLM size tiers (set `LocalVLMModelIdentifier` to match the model loaded in LM Studio):**

| Model | RAM at Q4 | When to pick it |
|---|---|---|
| `qwen3-vl-8b-instruct` | ~6 GB | Default. Best general-purpose grounding on 48 GB+ Macs. |
| `qwen3-vl-4b-instruct` | ~3 GB | 16-24 GB Macs. ~5-8 pts lower ScreenSpot accuracy but usable for everyday tasks. |
| `os-atlas-pro-7b` (GGUF) | ~5 GB | GUI-specialist alternative. Loads via `mradermacher/OS-Atlas-Pro-7B-GGUF`. |
| `ui-r1-e-3b` | ~2.5 GB | Lightest GUI-fine-tuned model with verified ScreenSpot numbers (89.5). Try if Qwen3-VL-4B feels too generic. |
| `smolvlm2-2.2b-instruct` | ~2 GB | Aggressively constrained devices (8 GB M1 base). Lowest quality but lowest footprint. |

**Heavier quantization** (when RAM is the constraint, not model choice): convert any of the above with `mlx-vlm`:

```bash
mlx_vlm.convert --hf-path Qwen/Qwen3-VL-4B-Instruct --quantize --q-bits 3
```

Q3 keeps most of the grounding quality at ~75% of Q4's size. ANE doesn't accelerate Q2, so Q3 is the practical floor.

**No usable LoRA adapters exist yet** for hot-swap on stock Qwen3-VL. Everything in the GUI-fine-tune space ships as merged full weights (see the model table above). LM Studio also doesn't expose adapter hot-loading today; if you genuinely need adapter swapping, switch to `mlx-lm` CLI or `llama-server --lora`.

**Reasoner sizing.** Point `LocalPlannerModelIdentifier` at any OpenAI-compatible model loaded in LM Studio. Suggested tiers:

| Model | Params (active) | RAM at Q4 | When to pick it |
|---|---|---|---|
| `qwen3-30b-a3b-thinking-2507` | 30B (3B active, MoE) | ~18 GB | **Default.** Qwen3's MoE thinking model — strong agent reasoning, fast inference, fits on 48 GB Macs alongside the VLM. |
| `gpt-oss-20b` | 20B (3.6B active, MoE) | ~13 GB | OpenAI's open-weights MoE, similar tier, slightly tighter footprint. Apache-2.0. |
| `phi-4-reasoning-14b` | 14B dense | ~9 GB | When you want frontier-ish reasoning on tighter hardware (32 GB Macs). |
| `qwen3-4b-instruct` | 4B dense | ~2.5 GB | Lower-end devices (8-16 GB). Expect noticeably weaker multi-step agent quality. |
| `phi-4-mini-reasoning` | ~3.8B dense | ~2.5 GB | Smallest viable. Equivalent tier to Qwen3-4B. |

Thinking-mode models emit `<think>…</think>` blocks; `LocalPlannerClient.stripThinkingBlocks` removes them before TTS and action-tag parsing, so you get the post-thought answer cleanly.

**VLM-skip heuristic** is on by default — pure-Q&A transcripts ("what is HTML", "explain async") skip the VLM call entirely. To disable for benchmarking, set `AlwaysRunLocalVLMRegardlessOfTranscript=true`.

## Latency tuning

Pace is positioned on speed. Time-to-first-spoken-word (TTFSW) is the headline metric — measured from PTT-release to the first audio dispatched. Every turn logs `⚡ TTFSW: NNNms` to the Xcode console and to the macOS unified log; `scripts/benchmark_ttfsw.sh` aggregates the distribution.

### Verify your numbers

```bash
# Use Pace normally for ~5 minutes, then:
./scripts/benchmark_ttfsw.sh --last 10m
```

Outputs a markdown table with n, min, p50, p95, max, mean for TTFSW and TTFT. Paste straight into PR descriptions or the landing page.

### Speculative decoding (latency win — 40-60% off generation phase)

The Apple Silicon decode loop is memory-bandwidth bound. Speculative decoding has a small draft model propose N tokens per memory pass, then the target model verifies them in one shot — lossless when the tokenizer family matches.

In LM Studio:

1. Download the draft model — **`qwen/qwen3-0.6b`** (or `qwen3-1.7b` if you want a higher acceptance rate at slightly more cost). Tokenizer must match the target (`qwen/qwen3-14b`), so stay inside the Qwen3 family.
2. Open the planner model's load configuration → **Speculative Decoding** → enable → select the draft model.
3. Reload the planner. Verify the LM Studio log shows `speculative decoding enabled` on the next request.

Expected: TTFT roughly unchanged, generation time drops 40-60% on cached prompts. The TTFSW number is the canonical signal — re-run the benchmark before and after to confirm.

If acceptance rate falls below ~0.5 (LM Studio logs it as `acc_rate=…`), speculative decoding will *slow* generation. Step down to a smaller/closer-distilled draft if that happens.

### Prompt-cache reuse

`LocalPlannerClient` ships `cache_prompt: true` in every chat-completions request. The llama.cpp engine inside LM Studio honors it; the MLX engine auto-caches prefixes regardless. The system prompt is a `static let`, so the request prefix is byte-stable across turns — exactly what the cache wants. Verify cache hits via TTFT: a cold first turn might be 600-1200ms, subsequent turns with the same model should drop into the 100-400ms range.

### Other knobs that move the needle

| Knob | Where | Effect |
|---|---|---|
| `--num-parallel 1` | LM Studio model load flags | Single-batch inference uses less KV cache, faster decode. |
| Drop `max_tokens` lower | `LocalPlannerClient.swift` | Shorter cap = earlier end-of-stream when the model's verbose. |
| Set Q4 → Q5 on the planner | LM Studio | Better quality, ~30% slower. Trade for accuracy when speed is acceptable. |
| Smaller VLM (`ui-venus-1.5-2b` default) | Info.plist `LocalVLMModelIdentifier` | Already on the smallest viable; OCR layer fills text fidelity. |

## Troubleshooting

**WhisperKit can't find a model:** ensure the `WhisperKitModel` identifier in Info.plist matches one of the available variants at <https://huggingface.co/argmaxinc/whisperkit-coreml>.

**LM Studio returns 404 on `/v1/chat/completions`:** ensure a model is *loaded* in LM Studio (not just downloaded), the server is started, and `LocalVLMModelIdentifier` matches the loaded model name exactly.

**"VLM analysis failed, falling back":** the cloud-only path still runs, so the app keeps working. Check Xcode console — most common cause is LM Studio not running or the model not yet loaded.

**Local TTS sounds robotic:** open System Settings → Accessibility → Spoken Content → System Voice → Manage Voices and download one of the "Premium" English voices. `LocalTTSClient` auto-prefers Premium > Enhanced > Default.
