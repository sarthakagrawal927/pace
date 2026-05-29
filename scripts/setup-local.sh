#!/usr/bin/env bash
#
# setup-local.sh — Provisions LM Studio + the local models pace needs.
#
# Idempotent: safe to re-run. Skips work that's already done. The only
# thing this script CAN'T do is build the app (per AGENTS.md you must
# Cmd+R in Xcode, not run xcodebuild from a terminal).
#
# WhisperKit is OPTIONAL — the default voice provider is Apple Speech
# (on-device, zero setup). Only add the WhisperKit SPM package if you
# specifically want to swap STT backends via VoiceTranscriptionProvider=
# whisperkit in Info.plist.
#
# Usage:
#   ./scripts/setup-local.sh          # full provision
#   ./scripts/setup-local.sh status   # just print state of the world
#
set -euo pipefail

LM_STUDIO_BIN="$HOME/.lmstudio/bin/lms"
LM_STUDIO_API_BASE="http://localhost:1234/v1"

# Models we want present + loaded. These names are what `lms` resolves
# against — append `@variant` if you need a specific quantization.
PLANNER_MODEL_NAME="qwen/qwen3-30b-a3b"
PLANNER_CONTEXT_LENGTH=8192
# UI-Venus-1.5-8B is the GUI specialist this build defaults to. It
# isn't in LM Studio's curated hub, so we grab it directly from the
# HuggingFace mlx-community mirror. Fallback is Qwen2.5-VL-7B which
# IS in the LM Studio hub.
VLM_HF_REPO_PRIMARY="mlx-community/UI-Venus-1.5-8B-4bit"
VLM_HF_FOLDER_NAME_PRIMARY="UI-Venus-1.5-8B-4bit"
VLM_LMS_FALLBACK="qwen/qwen2.5-vl-7b-instruct"

print_step() {
    printf "\n\033[36m▸ %s\033[0m\n" "$1"
}

print_warn() {
    printf "\033[33m! %s\033[0m\n" "$1"
}

print_ok() {
    printf "\033[32m✓ %s\033[0m\n" "$1"
}

print_fail() {
    printf "\033[31m✗ %s\033[0m\n" "$1"
}

ensure_brew_present() {
    if ! command -v brew >/dev/null 2>&1; then
        print_fail "Homebrew is not installed. Install it from https://brew.sh and re-run this script."
        exit 1
    fi
    print_ok "Homebrew found ($(brew --version | head -1))"
}

ensure_lm_studio_app_present() {
    if [ -d "/Applications/LM Studio.app" ]; then
        print_ok "LM Studio.app present"
        return
    fi
    print_step "Installing LM Studio via brew..."
    brew install --cask lm-studio
    print_ok "LM Studio.app installed"
}

ensure_lms_cli_present() {
    if [ -x "$LM_STUDIO_BIN" ]; then
        print_ok "lms CLI present at $LM_STUDIO_BIN"
        return
    fi
    print_warn "lms CLI not yet installed."
    print_warn "Opening LM Studio once to bootstrap the CLI (first launch installs ~/.lmstudio/bin/lms)..."
    open -a "LM Studio"
    # Wait up to 60s for the CLI to appear.
    for _attempt in $(seq 1 30); do
        if [ -x "$LM_STUDIO_BIN" ]; then
            print_ok "lms CLI bootstrapped"
            return
        fi
        sleep 2
    done
    print_fail "lms CLI did not appear after 60s. Open LM Studio manually, finish the onboarding, then re-run this script."
    exit 1
}

ensure_server_running() {
    if curl -sS --max-time 2 "${LM_STUDIO_API_BASE}/models" >/dev/null 2>&1; then
        print_ok "LM Studio server already responding at ${LM_STUDIO_API_BASE}"
        return
    fi
    print_step "Starting LM Studio server..."
    "$LM_STUDIO_BIN" server start
    # Wait for it to come up.
    for _attempt in $(seq 1 15); do
        if curl -sS --max-time 2 "${LM_STUDIO_API_BASE}/models" >/dev/null 2>&1; then
            print_ok "Server is up"
            return
        fi
        sleep 1
    done
    print_fail "Server did not respond after 15s. Check 'lms server status'."
    exit 1
}

model_is_present_on_disk() {
    local target_model_name="$1"
    "$LM_STUDIO_BIN" ls 2>/dev/null | grep -q -i "$target_model_name"
}

download_model_if_missing() {
    local target_model_name="$1"
    if model_is_present_on_disk "$target_model_name"; then
        print_ok "Model already on disk: $target_model_name"
        return 0
    fi
    print_step "Downloading $target_model_name (this can be several GB)..."
    if "$LM_STUDIO_BIN" get "$target_model_name" --mlx --yes; then
        print_ok "Downloaded $target_model_name"
        return 0
    fi
    print_warn "Failed to download $target_model_name"
    return 1
}

ensure_vlm_available() {
    if model_is_present_on_disk "ui-venus" \
        || model_is_present_on_disk "qwen2.5-vl" \
        || model_is_present_on_disk "qwen2_5-vl" \
        || model_is_present_on_disk "qwen3-vl"; then
        print_ok "A VLM is already on disk"
        return
    fi

    # UI-Venus-1.5-8B isn't in LM Studio's curated hub; we pull it from
    # mlx-community directly via the HF CLI. Requires huggingface-cli
    # or the new `hf` binary on PATH.
    local hf_cli=""
    if command -v hf >/dev/null 2>&1; then
        hf_cli="hf"
    elif command -v huggingface-cli >/dev/null 2>&1; then
        hf_cli="huggingface-cli"
    fi

    if [ -n "$hf_cli" ]; then
        local target_dir="$HOME/.lmstudio/models/mlx-community/$VLM_HF_FOLDER_NAME_PRIMARY"
        if [ ! -d "$target_dir" ]; then
            print_step "Downloading $VLM_HF_REPO_PRIMARY via $hf_cli (~5 GB)..."
            mkdir -p "$HOME/.lmstudio/models/mlx-community"
            (cd "$HOME/.lmstudio/models/mlx-community" && "$hf_cli" download "$VLM_HF_REPO_PRIMARY" --local-dir "$VLM_HF_FOLDER_NAME_PRIMARY")
            print_ok "Downloaded UI-Venus-1.5-8B"
            return
        fi
        print_ok "UI-Venus-1.5-8B already on disk at $target_dir"
        return
    fi

    print_warn "No HF CLI found. Falling back to LM Studio hub Qwen2.5-VL."
    if download_model_if_missing "$VLM_LMS_FALLBACK"; then
        return
    fi
    print_fail "Could not download any VLM automatically."
    print_warn "Install huggingface_hub ('pip install -U huggingface_hub') and re-run, or download a VLM manually via LM Studio UI."
    exit 1
}

ensure_models_loaded() {
    print_step "Loading planner ($PLANNER_MODEL_NAME) with ${PLANNER_CONTEXT_LENGTH} context..."
    "$LM_STUDIO_BIN" load "$PLANNER_MODEL_NAME" --context-length "$PLANNER_CONTEXT_LENGTH" 2>&1 | tail -2
    print_step "Loading VLM (ui-venus-1.5-8b)..."
    "$LM_STUDIO_BIN" load "ui-venus-1.5-8b" 2>&1 | tail -2 || true
}

print_loaded_models_and_suggested_info_plist_values() {
    print_step "Loaded models in memory:"
    "$LM_STUDIO_BIN" ps 2>&1 | sed 's/^/    /'

    print_step "Models on disk:"
    "$LM_STUDIO_BIN" ls 2>&1 | sed 's/^/    /'

    print_step "Verifying the OpenAI-compatible /v1/models endpoint:"
    curl -sS "${LM_STUDIO_API_BASE}/models" | head -c 800
    printf "\n"

    print_step "Info.plist identifiers to confirm match what's loaded:"
    echo "    LocalPlannerModelIdentifier  → whatever ID appears for your 30B-A3B planner in the /v1/models output above"
    echo "    LocalVLMModelIdentifier      → whatever ID appears for your vision model"
    echo "    (If the IDs in leanring-buddy/Info.plist don't match exactly, update them before Cmd+R.)"
}

case "${1:-provision}" in
    status)
        print_step "Status only — not provisioning."
        ensure_brew_present
        if [ -d "/Applications/LM Studio.app" ]; then print_ok "LM Studio.app present"; else print_warn "LM Studio.app missing"; fi
        if [ -x "$LM_STUDIO_BIN" ]; then print_ok "lms CLI present"; else print_warn "lms CLI missing"; fi
        if curl -sS --max-time 2 "${LM_STUDIO_API_BASE}/models" >/dev/null 2>&1; then
            print_ok "LM Studio server responding"
        else
            print_warn "LM Studio server not responding"
        fi
        if [ -x "$LM_STUDIO_BIN" ]; then
            print_loaded_models_and_suggested_info_plist_values
        fi
        ;;
    provision)
        print_step "Provisioning local stack for pace..."
        ensure_brew_present
        ensure_lm_studio_app_present
        ensure_lms_cli_present
        ensure_server_running
        ensure_vlm_available
        ensure_models_loaded
        print_loaded_models_and_suggested_info_plist_values
        print_step "Next manual steps:"
        echo "    1. Open leanring-buddy.xcodeproj in Xcode"
        echo "    2. Cmd+R to build and run. DO NOT run xcodebuild from terminal — it invalidates TCC permissions."
        echo "    3. When prompted, grant: Microphone, Accessibility, Screen Recording, Speech Recognition."
        echo
        echo "    Optional: to use WhisperKit STT instead of Apple Speech,"
        echo "    File → Add Package Dependencies → https://github.com/argmaxinc/WhisperKit"
        echo "    then set VoiceTranscriptionProvider=whisperkit in Info.plist."
        print_ok "Provisioning complete."
        ;;
    *)
        echo "Usage: $0 [status|provision]" >&2
        exit 1
        ;;
esac
